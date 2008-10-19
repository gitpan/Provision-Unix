package Provision::Unix::DNS::NicTool;

use warnings;
use strict;

our $VERSION = '0.22';

use English qw( -no_match_vars );
use Params::Validate qw(:all);

sub new {
    my $class = shift;

    my %p = validate( @_, { 'prov' => { type => HASHREF }, } );

    my $self = { prov => $p{prov}, };
    bless( $self, $class );

    $self->{nt} = $self->connect();
    return $self;
}

sub connect {

    my $self = shift;
    my $prov = $self->{prov};

    eval { require NicTool; };

    if ($EVAL_ERROR) {
        $prov->error( message =>
    "Could not load NicTool.pm. Are the NicTool client libraries installed? They can be found in NicToolServer/sys/client in the NicToolServer distribution. See http://nictool.com/"
        );
    }

    my $nt = NicTool->new(
        server_host => $self->{prov}{config}{NicTool}{server_host},
        server_port => $self->{prov}{config}{NicTool}{server_port},
        protocol    => $self->{prov}{config}{NicTool}{protocol},
    );

    my $user = $self->{prov}{config}{NicTool}{username};
    my $pass = $self->{prov}{config}{NicTool}{password};

    $prov->audit("logging into nictool with $user:$pass");

    my $r = $nt->login( username => $user, password => $pass );

    if ( $nt->is_error($r) ) {
        $prov->error( message => "error logging in: $r->{store}{error_msg}" );
    }

    #warn Data::Dumper::Dumper( $nt ); # ->{user}{store} );

    $prov->audit(
        "\tlogin successful (session " . $nt->{nt_user_session} . ")" );
    return $nt;
}

sub create_zone {
    my $self = shift;

    my %p = validate(
        @_,
        {   'zone'        => { type => SCALAR },
            'contact'     => { type => SCALAR | UNDEF, optional => 1 },
            'ttl'         => { type => SCALAR | UNDEF, optional => 1 },
            'refresh'     => { type => SCALAR | UNDEF, optional => 1 },
            'retry'       => { type => SCALAR | UNDEF, optional => 1 },
            'expire'      => { type => SCALAR | UNDEF, optional => 1 },
            'minimum'     => { type => SCALAR | UNDEF, optional => 1 },
            'nameservers' => { type => SCALAR | UNDEF, optional => 1, },
            'template'    => { type => SCALAR | UNDEF, optional => 1, },
            'ip'          => { type => SCALAR | UNDEF, optional => 1, },
            'mailip'      => { type => SCALAR | UNDEF, optional => 1, },
            'fatal'       => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'       => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $prov = $self->{prov};
    $prov->audit("creating zone $p{zone}");

    my $nt = $self->{nt};

## TODO
# if nameservers are not set, or set to a special value, then select them from
# usable_nsN in the $nt->{user}{store} object

    my $r = $nt->new_zone(
        nt_zone_id  => undef,
        nt_group_id => $nt->{user}{store}{nt_group_id},
        zone        => $p{zone},
        ttl         => $p{ttl} || $prov->{config}{DNS}{zone_ttl},
        serial      => undef,
        nameservers => $p{nameservers}
            || $prov->{config}{NicTool}{nameservers}
            || '1,2',
        mailaddr => $p{contact} || 'hostmaster.' . $p{zone},
        refresh  => $p{refresh} || $prov->{config}{DNS}{zone_refresh},
        retry    => $p{retry}   || $prov->{config}{DNS}{zone_retry},
        expire   => $p{expire}  || $prov->{config}{DNS}{zone_expire},
        minimum  => $p{minimum} || $prov->{config}{DNS}{zone_minimum},
    );

    if ( $r->{store}{error_code} != 200 ) {
        $prov->error(
            message => "\t$r->{store}{error_desc} ( $r->{store}{error_msg} )",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
        return;
    }

    my $zone_id = $r->{store}{nt_zone_id};
    $prov->audit("\tcreated ( $zone_id ) ");
    return $zone_id;

## TODO
    # add zone records if $p{template}

}

sub create_zone_record {

    my $self = shift;

    my %p = validate(
        @_,
        {   'zone'     => { type => SCALAR },
            'zone_id'  => { type => SCALAR, optional => 1 },
            'type'     => { type => SCALAR },
            'name'     => { type => SCALAR },
            'address'  => { type => SCALAR },
            'weight'   => { type => SCALAR, optional => 1 },
            'ttl'      => { type => SCALAR, optional => 1 },
            'priority' => { type => SCALAR, optional => 1 },
            'port'     => { type => SCALAR, optional => 1 },
        }
    );

    my %valid_types = map { $_ => 1 } qw/ A MX CNAME NS SRV TXT/;

    my $prov = $self->{prov};
    my $type = $p{type};

    if ( !$valid_types{$type} ) {
        $prov->error( message => 'invalid record type', fatal => $p{fatal} );
    }

    $prov->audit("creating $type record in $p{zone}");

    my $zone_id = $p{zone_id} || $self->get_zone_id( zone => $p{zone} );

    my %request = (
        nt_zone_record_id => undef,
        nt_zone_id        => $zone_id,
        type              => $type,
        name              => $p{name},
        address           => $p{address},
        ttl               => $p{ttl} || $prov->{config}{DNS}{ttl},
    );

    if ( $type =~ /(mx|srv)/i ) {
        $request{weight} = $p{weight} || $prov->{config}{DNS}{weight};
    }
    if ( lc($type) eq 'srv' ) {
        $request{priority} = $p{priority} || 5;
        $request{port} = $p{port}
            || $prov->error( message => 'SRV records require a port' );
    }

    my $nt = $self->{nt};
    my $r  = $nt->new_zone_record(%request);

    if ( $r->{store}{error_code} != 200 ) {
        $prov->error(
            message => "$r->{store}{error_desc} ( $r->{store}{error_msg} )" );
        return;
    }

    #warn Data::Dumper::Dumper($r->{store});

    my $zone_rec_id = $r->{store}{nt_zone_record_id};
    $prov->audit("\tsuccess (record id: $zone_rec_id)");
    return $zone_rec_id;
}

sub get_zone {

    my $self = shift;

    my %p = validate(
        @_,
        {   'zone'  => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $prov = $self->{prov};
    $prov->audit("getting zone $p{zone}");

    my $nt = $self->{nt};

    my $r = $nt->get_group_zones(
        nt_group_id       => $nt->{user}{store}{nt_group_id},
        include_subgroups => 1,
        Search            => 1,
        '1_field'         => "zone",
        '1_option'        => "equals",
        '1_value'         => $p{zone},
    );

    #warn Data::Dumper::Dumper($r);

    if ( $r->{store}{error_code} != 200 ) {
        return $prov->error(
            message => "$r->{store}{error_desc} ( $r->{store}{error_msg} )",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
    }

    if ( !$r->{store}{zones}[0]{store}{nt_zone_id} ) {
        return $prov->error(
            message => "\tzone not found!",
            fatal   => $p{fatal},
            debug   => $p{debug},
        );
    }

    my $zone_id = $r->{store}{zones}[0]{store}{nt_zone_id};
    $prov->audit("\tfound zone (id: $zone_id)");
    return $zone_id;
}

sub delete_zone {

    my $self = shift;

    my %p = validate(
        @_,
        {   'id'   => { type => SCALAR, optional => 1 },
            'zone' => { type => SCALAR },
            'fatal' => { type => BOOLEAN, optional => 1, default => 1 },
            'debug' => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );

    my $prov = $self->{prov};
    $prov->audit("getting zone $p{zone}");

    my $id = $p{id} || $self->get_zone_id( zone => $p{zone} );

    my $nt = $self->{nt};
    my $r = $nt->delete_zones( zone_list => [$id], );

    if ( $r->{store}{error_code} != 200 ) {
        $prov->error(
            message => "$r->{store}{error_desc} ( $r->{store}{error_msg} )" );

        #warn Data::Dumper::Dumper($r);
        return;
    }

    return $id;
}

sub delete_zone_record {
    my $self = shift;

    my %p = validate(
        @_,
        {   'id'     => { type => SCALAR, optional => 1 },
            'zone'   => { type => SCALAR },
            'record' => { type => SCALAR },
            'fatal'  => { type => BOOLEAN, optional => 1, default => 1 },
            'debug'  => { type => BOOLEAN, optional => 1, default => 1 },
        }
    );


}

1;

=head1 NAME

Provision::Unix::DNS::NicTool - Provision NicTool DNS entries

=head1 VERSION

Version 0.22

=head1 SYNOPSIS

Provision DNS entries into a NicTool DNS management system using the NicTool native API.

    use Provision::Unix::DNS::NicTool;

    my $dns = Provision::Unix::DNS::NicTool->new();
    ...


=head1 FUNCTIONS


=head1 AUTHOR

Matt Simerson, C<< <matt at tnpi.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-unix-provision-dns at rt.cpan.org>, or through the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Provision-Unix>.  I will be notified, and then you'll automatically be notified of progress on your bug as I make changes.



=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Provision::Unix::DNS::NicTool


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Provision-Unix>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Provision-Unix>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Provision-Unix>

=item * Search CPAN

L<http://search.cpan.org/dist/Provision-Unix>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2008 Matt Simerson, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

