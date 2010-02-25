package CPAN::Patches;

=head1 NAME

CPAN::Patches - patch CPAN distributions

=head1 SYNOPSIS

    cd Some-Distribution
    cpan-patches patch

or

    cd Some-Distribution
    dh-make-perl
    cpan-patches update-debian

=head1 DESCRIPTION

This module allows to apply custom patches to the CPAN distributions.

See L</patch> and L</update_debian> for a detail description how.

See L<http://github.com/jozef/CPAN-Patches-Set> for example generated
Debian patches set folder.

=cut

use warnings;
use strict;

our $VERSION = '0.01';

use Moose;
use CPAN::Patches::SPc;
use Carp;
use IO::Any;
use JSON::Util;
use File::chdir;
use YAML::Syck qw();
use Scalar::Util 'blessed';
use File::Path 'make_path';
use Storable 'dclone';
use Test::Deep::NoTest 'eq_deeply';
use File::Copy 'copy';
use Parse::Deb::Control '0.03';
use Dpkg::Version 'version_compare';

=head1 PROPERTIES

=head2 patch_set_location

A folder where are the distribution patches located. Default is
F<< Sys::Path->sharedstatedir/cpan-patches/set >> which is
F</var/lib/cpan-patches/set> on Linux.

=head2 verbose

Turns on/off some verbose output. By default it is on.

=cut

has 'patch_set_location' => (
    is      => 'rw',
    isa     => 'Str',
    lazy    => 1,
    default => sub { File::Spec->catdir(CPAN::Patches::SPc->sharedstatedir, 'cpan-patches', 'set') }
);
has 'verbose' => ( is => 'rw', isa => 'Int', default => 1 );

=head1 METHODS

=head2 new()

Object constructor.

=head2 patch

Apply all patches that are listed in F<.../module-name/patches/series>.

=cut

sub patch {
    my $self = shift;
    my $path = shift || '.';
    
    $self = $self->new()
        if not blessed $self;
    
    local $CWD = $path;
 
    my $meta = $self->read_meta($path);
    my $name = $self->clean_meta_name($meta->{'name'}) or croak 'no name in meta';
    
    foreach my $patch_filename ($self->get_patch_series($name)) {
        print 'patching ', $name,' with ', $patch_filename, "\n"
            if $self->verbose;
        system('cat '.$patch_filename.' | patch -p1');
    }
    
    return;
}

=head2 update_debian

Copy all patches and F<series> file from F<.../module-name/patches/> to
F<debian/patches> folder. If there are any patches add C<quilt> as
C<Build-Depends-Indep> and runs adds C<--with quilt> to F<debian/rules>.
Adds dependencies from F<.../module-name/debian>, adds usage of C<xvfb-run>
if the modules requires X and renames C<s/lib(.*)-perl/$1/> if the distribution
is an application.

=cut

sub update_debian {
    my $self = shift;
    my $path = shift || '.';
    
    $self = $self->new()
        if not blessed $self;
    
    my $debian_path             = File::Spec->catdir($path, 'debian');
    my $debian_patches_path     = File::Spec->catdir($debian_path, 'patches');
    my $debian_control_filename = File::Spec->catdir($debian_path, 'control');
    croak 'debian/ folder not found'
        if not -d $debian_path;

    my $meta     = $self->read_meta($path);
    my $name     = $self->clean_meta_name($meta->{'name'}) or croak 'no name in meta';
    my $debian_data = $self->read_debian($name);
    my $deb_control = Parse::Deb::Control->new([$debian_control_filename]);
    
    die $name.' has disabled auto build'
        if $debian_data->{'No-Auto'};
    
    my @series = $self->get_patch_series($name);
    if (@series) {
        make_path($debian_patches_path)
            if not -d $debian_patches_path;
            
        foreach my $patch_filename (@series) {
            print 'copy ', $patch_filename,' to ', $debian_patches_path, "\n"
                if $self->verbose;
            copy($patch_filename, $debian_patches_path);
        }
        IO::Any->spew([$debian_patches_path, 'series'], join("\n", @series));
    }

    # write new debian/rules
    IO::Any->spew(
        [$debian_path, 'rules'],
        "#!/usr/bin/make -f\n\n%:\n	"
        .($debian_data->{'X'} ? 'xvfb-run -a ' : '')
        .'dh '.(@series ? '--with quilt ': '').'$@'
        ."\n"
    );
    
    # update dependencies
    foreach my $dep_type ('Depends', 'Build-Depends', 'Build-Depends-Indep') {
        my $dep = {CPAN::Patches->get_deb_package_names($deb_control, $dep_type)};
        my $new_dep = CPAN::Patches->merge_debian_versions($dep, $debian_data->{$dep_type} || {});
        
        if ($debian_data->{'X'} and ($dep_type eq 'Build-Depends-Indep')) {
            $new_dep->{'xauth'} = '';
            $new_dep->{'xvfb'}  = '';
        }
        if (@series and ($dep_type eq 'Build-Depends-Indep')) {
            $new_dep->{'quilt'} = '';
        }
        
        # update if dependencies if needed
        if (not eq_deeply($dep, $new_dep)) {
            my ($control_key) = $deb_control->get_keys($dep_type =~ m/Build/ ? 'Source' : 'Package');
            next if not $control_key;
            
            my $new_value =
                ' '.(
                    join ', ',
                    map { $_.($new_dep->{$_} ? ' '.$new_dep->{$_} : '') }
                    sort
                    keys %{$new_dep}
                )."\n"
            ;
            $control_key->{'para'}->{$dep_type} = $new_value;
        }
    }
    IO::Any->spew([$debian_control_filename], $deb_control->control);
    
    if (my $app_name = $debian_data->{'App'}) {
        local $CWD = $debian_path;
        my $lib_name = 'lib'.$name.'-perl';
        system(q{perl -lane 's/}.$lib_name.q{/}.$app_name.q{/;print' -i *});
        foreach my $filename (glob($lib_name.'*')) {
            rename($filename, $app_name.substr($filename, 0-length($lib_name)));
        }
    }
    
    
    return;
}

=head1 INTERNAL METHODS

=head2 merge_debian_versions($v1, $v2)

Merges dependecies from C<$v1> and C<$v2> by keeping the ones that has
higher version (if the same).

=cut

sub merge_debian_versions {
    my $self = shift;
	my $versions1_orig = shift or die;
	my $versions2      = shift or die;
	
	my $versions1 = dclone $versions1_orig;
	
	while (my ($p, $v2) = each %{$versions2}) {
		if (exists $versions1->{$p}) {
			next if not $v2;
			my $v1 = $versions1->{$p} || '(>= 0)';
			if ($v1 !~ m/\(\s* >= \s* ([^\)]+?) \s*\)/xms) {
				warn 'invalid version '.$v1.' in conflic resolution';
				die;
				next;
			}
			my $v1n = $1;
			if ($v2 !~ m/\(\s* >= \s* ([^\)]+?) \s*\)/xms) {
				warn 'invalid version '.$v2.' in conflic resolution';
				die;
				next;
			}
			my $v2n = $1;

			# only when newer version is needed
			$versions1->{$p} = $v2
				if version_compare($v2n, $v1n) == 1;
		}
		else {
			$versions1->{$p} = $v2;
		}
	}
	
	return $versions1;    
}

=head2 get_deb_package_names($control, $key)

Return hash with package name as key and version string as value for
given C<$key> in Debian C<$control> file.

=cut

sub get_deb_package_names {
    my $self    = shift;
    my $control = shift or croak 'pass control object';
    my $key     = shift or croak 'pass key name';
	
	return
		map {
			my ($p, $v) = split('\s+', $_, 2);
			$v ||= '';
			($p => $v)
		}
		grep { $_ }
		map { s/^\s*//;$_; }
		map { s/\s*$//;$_; }
		map { split(',', $_) }
		map { ${$_->{'value'}} }
		$control->get_keys($key)
	;
}

=head2 read_debian($name)

Read F<.../module-name/debian> for given C<$name>.

=cut

sub read_debian {
    my $self = shift;
    my $name = shift or croak 'pass name param';
    
    my $debian_filename  = File::Spec->catfile($self->patch_set_location, $name, 'debian');
    return {}
        if not -r $debian_filename;
    
    return $self->decode_debian([$debian_filename]);
}

=head2 decode_debian($src)

Parses F<.../module-name/debian> into a hash. Returns hash reference.

=cut

sub decode_debian {
    my $self = shift;
    my $src  = shift or die 'pass source';
    
    my $deb_control = Parse::Deb::Control->new($src);
    my %depends             = CPAN::Patches->get_deb_package_names($deb_control, 'Depends');
    my %build_depends       = CPAN::Patches->get_deb_package_names($deb_control, 'Build-Depends');
    my %build_depends_indep = CPAN::Patches->get_deb_package_names($deb_control, 'Build-Depends-Indep');
    my ($app) = 
        map { s/^\s*//;$_; }
		map { s/\s*$//;$_; }
		map { ${$_->{'value'}} }
		$deb_control->get_keys('App')
    ;
    my ($x_for_testing) = 
        map { s/^\s*//;$_; }
		map { s/\s*$//;$_; }
		map { ${$_->{'value'}} }
		$deb_control->get_keys('X')
    ;
    my ($no_auto) = 
        map { s/^\s*//;$_; }
		map { s/\s*$//;$_; }
		map { ${$_->{'value'}} }
		$deb_control->get_keys('No-Auto')
    ;

    
    return {
        'Depends'             => \%depends,
        'Build-Depends'       => \%build_depends,
        'Build-Depends-Indep' => \%build_depends_indep,
        (defined $app ? ('App' => $app) : ()),
        (defined $x_for_testing ? ('X' => $x_for_testing) : ()),
        (defined $no_auto ? ('No-Auto' => $no_auto) : ()),
    };
}

=head2 encode_debian($data)

Return F<.../module-name/debian> content string generated from C<$data>.

=cut

sub encode_debian {
    my $self = shift;
    my $data = shift;
    
    my $content = '';
    $content .= 'App: '.$data->{'App'}."\n"
        if exists $data->{'App'};
    
    foreach my $dep_type ('Build-Depends', 'Build-Depends-Indep', 'Depends') {
        next if (not $data->{$dep_type}) or (not keys %{$data->{$dep_type}});
        
        my $new_value = (
            join ', ',
            map { $_.($data->{$dep_type}->{$_} ? ' '.$data->{$dep_type}->{$_} : '') }
            sort
            keys %{$data->{$dep_type}}
        );
        $content .= $dep_type.': '.$new_value."\n";
    }

    $content .= 'No-Auto: '.$data->{'No-Auto'}."\n"
        if exists $data->{'No-Auto'};
    $content .= 'X: '.$data->{'X'}."\n"
        if exists $data->{'X'};
    
    return $content;
}

=head2 get_patch_series($module_name)

Return an array of patches filenames for given C<$module_name>.

=cut

sub get_patch_series {
    my $self = shift;
    my $name = shift or croak 'pass name param';
    
    my $patches_folder  = File::Spec->catdir($self->patch_set_location, $name, 'patches');
    my $series_filename = File::Spec->catfile($patches_folder, 'series');
    
    return if not -r $series_filename;
    
    return
        map  { File::Spec->catfile($patches_folder, $_) }
        map  { s/^\s*//;$_; }
        map  { s/\s*$//;$_; }
        map  { split "\n" }
        eval { IO::Any->slurp([$series_filename]) };
}

=head2 clean_meta_name($name)

Returns lowercased :: by - substituted and trimmed module name.

=cut

sub clean_meta_name {
    my $self = shift;
    my $name = shift || '';
    
    $name =~ s/::/-/xmsg;
    $name =~ s/\s*$//;
    $name =~ s/^\s*//;
    $name = lc $name;

    return $name;    
}

=head2 read_meta([$path])

Reads a F<META.yml> or F<META.json> from C<$path>. If C<$path> is not provided
than tries to read from current folder.

=cut

sub read_meta {
    my $self = shift;
    my $path = shift || '.';
    
    my $yml  = File::Spec->catfile($path, 'META.yml');
    my $json = File::Spec->catfile($path, 'META.json');
    if (-f $json) {
        my $meta = eval { JSON::Util->decode([$json]) };
        return $meta
            if $meta;
    }
    if (-f $yml) {
        my $meta = eval { YAML::Syck::LoadFile($yml) };
        return $meta
            if $meta;
    }
    croak 'failed to read meta file';
}

1;


__END__

=head1 AUTHOR

jozef@kutej.net, C<< <jkutej at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-cpan-patches at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CPAN-Patches>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc CPAN::Patches


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=CPAN-Patches>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/CPAN-Patches>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/CPAN-Patches>

=item * Search CPAN

L<http://search.cpan.org/dist/CPAN-Patches/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of CPAN::Patches
