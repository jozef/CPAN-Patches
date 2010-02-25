package CPAN::Patches::SPc;

=head1 NAME

Acme::SysPath::SPc - build-time system path configuration

=cut

use warnings;
use strict;

our $VERSION = '0.01';

use File::Spec;

sub _path_types {qw(
	sharedstatedir
)};

=head1 PATHS

=head2 prefix

=head2 sharedstatedir

Used to lookup for patches set.

=cut

sub prefix     { use Sys::Path; Sys::Path->find_distribution_root(__PACKAGE__); };
sub sharedstatedir { File::Spec->catdir(__PACKAGE__->prefix, 'sharedstate') };

1;


__END__

=head1 AUTHOR

Jozef Kutej

=cut
