# Copyright 2001-2006 The Apache Software Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

package AxKit2::Connection;

use strict;
use warnings;
use base qw(Danga::Socket AxKit2::Client);

use AxKit2::HTTPHeaders;
use AxKit2::Constants;
use AxKit2::Processor;
use AxKit2::Utils qw(http_date);

use fields qw(
    alive_time
    create_time
    headers_string
    headers_in
    headers_out
    ditch_leading_rn
    server_config
    http_headers_sent
    notes
    sock_closed
    );

use constant CLEANUP_TIME => 5; # every N seconds
use constant MAX_HTTP_HEADER_LENGTH => 102400; # 100k

our $last_cleanup = 0;

Danga::Socket->AddTimer(CLEANUP_TIME, \&_do_cleanup);

sub new {
    my AxKit2::Connection $self = shift;
    my $sock = shift;
    my $servconf = shift;
    $self = fields::new($self) unless ref($self);
    
    $self->SUPER::new($sock);

    my $now = time;
    $self->{alive_time} = $self->{create_time} = $now;
    
    $self->{headers_string} = '';
    $self->{closed} = 0;
    $self->{ditch_leading_rn} = 0; # TODO - work out how to set that...
    $self->{server_config} = $servconf;
    $self->{notes} = {};
    
    $self->log(LOGINFO, "Connection from " . $self->peer_addr_string);
    # allow connect hook to disconnect us
    $self->hook_connect() or return;
    
    return $self;
}

sub uptime {
    my AxKit2::Connection $self = shift;
    
    return (time() - $self->{create_time});
}

sub config {
    my AxKit2::Connection $self = shift;
    if ($self->{headers_in}) {
        return $self->{server_config}->get_config($self->{headers_in}->request_uri);
    }
    return $self->{server_config};
}

sub notes {
    my AxKit2::Connection $self = shift;
    my $key  = shift;
    @_ and $self->{notes}->{$key} = shift;
    $self->{notes}->{$key};
}

sub max_idle_time       { 30 }
sub max_connect_time    { 180 }
sub event_err { my AxKit2::Connection $self = shift; $self->close("Error") }
sub event_hup { my AxKit2::Connection $self = shift; $self->close("Disconnect (HUP)") }
sub close     { my AxKit2::Connection $self = shift; $self->{sock_closed}++; $self->SUPER::close(@_) }

sub event_read {
    my AxKit2::Connection $self = shift;
    $self->{alive_time} = time;
    
    if ($self->{headers_in}) {
        # already got the headers... do we get a body too?
        my $bref = $self->read(8192);
        return $self->close($!) unless defined $bref;
        return $self->hook_body_data($bref);
    }
    my $to_read = MAX_HTTP_HEADER_LENGTH - length($self->{headers_string});
    my $bref = $self->read($to_read);
    return $self->close($!) unless defined $bref;
    
    $self->{headers_string} .= $$bref;
    my $idx = index($self->{headers_string}, "\r\n\r\n");
    
    if ($idx == -1) {
        # usually we get the headers all in one packet (one event), so
        # if we get in here, that means it's more than likely the
        # extra \r\n and if we clean it now (throw it away), then we
        # can avoid a regexp later on.
        if ($self->{ditch_leading_rn} && $self->{headers_string} eq "\r\n") {
            print "  throwing away leading \\r\\n\n" if $::DEBUG >= 3;
            $self->{ditch_leading_rn} = 0;
            $self->{headers_string}   = "";
            return;
        }
        
        $self->close('long_headers')
            if length($self->{headers_string}) >= MAX_HTTP_HEADER_LENGTH;
        return;
    }
    
    my $hstr = substr($self->{headers_string}, 0, $idx);
    print "  pre-parsed headers: [$hstr]\n" if $::DEBUG >= 3;
    
    my $extra = substr($self->{headers_string}, $idx+4);
    
    if (my $len = length($extra)) {
        print "  pushing back $len bytes after header\n" if $::DEBUG >= 3;
        $self->push_back_read(\$extra);
    }

    # some browsers send an extra \r\n after their POST bodies that isn't
    # in their content-length.  a base class can tell us when they're
    # on their 2nd+ request after a POST and tell us to be ready for that
    # condition, and we'll clean it up
    $hstr =~ s/^\r\n// if $self->{ditch_leading_rn};

    $self->{headers_in} = AxKit2::HTTPHeaders->new(\$hstr);
    
    $self->{ditch_leading_rn} = 0;
    
    $self->process_request() if $self->{headers_in}->request_method =~ /GET|HEAD/;
}

sub headers_out {
    my AxKit2::Connection $self = shift;
    @_ and $self->{headers_out} = shift;
    $self->{headers_out};
}

sub headers_in {
    my AxKit2::Connection $self = shift;
    $self->{headers_in};
}

sub param {
    my AxKit2::Connection $self = shift;
    $self->{headers_in}->param(@_);
}

sub send_http_headers {
    my AxKit2::Connection $self = shift;
    
    return if $self->{http_headers_sent}++;
    $self->write($self->headers_out->to_string_ref);
}

sub process_request {
    my AxKit2::Connection $self = shift;
    my $hd = $self->{headers_in};
    my $conf = $self->{server_config};

    $self->{headers_out} = AxKit2::HTTPHeaders->new_response;
    $self->{headers_out}->header(Date   => http_date());
    $self->{headers_out}->header(Server => "AxKit-2/v$AxKit2::VERSION");
    
    $self->hook_uri_to_file($hd, $hd->request_uri)
    &&
    $self->hook_mime_map($hd, $hd->filename)
    &&
    $self->hook_access_control($hd)
    &&
    $self->hook_authentication($hd)
    &&
    $self->hook_authorization($hd)
    &&
    $self->hook_fixup($hd)
    &&
    (
        $self->hook_xmlresponse(AxKit2::Processor->new($self, $hd->filename))
        ||
        $self->hook_response($hd)
    );
    
    $self->write(sub { $self->http_response_sent() });

#    use Devel::GC::Helper;
#    use Data::Dumper;
#    $Data::Dumper::Terse = 1;
#    $Data::Dumper::Indent = 1;
#    #$Data::Dumper::Deparse = 1;
#    my $leaks = Devel::GC::Helper::sweep;
#    foreach my $leak (@$leaks) {
#        print "Leaked $leak\n";
#        print Dumper($leak);
#    }
#    print "Total leaks: " . scalar(@$leaks) . "\n";                                                 
}

# called when we've finished writing everything to a client and we need
# to reset our state for another request.  returns 1 to mean that we should
# support persistence, 0 means we're discarding this connection.
sub http_response_sent {
    my AxKit2::Connection $self = $_[0];
    
    if ($self->hook_response_sent($self->{headers_out}->response_code)) {
        $self->close("plugin");
        return 0;
    }
    
    return 0 if $self->{sock_closed};
    
    # close if we're supposed to
    if (
        ! defined $self->{headers_out} ||
        ! $self->{headers_out}->res_keep_alive($self->{headers_in})
        )
    {
        # do a final read so we don't have unread_data_waiting and RST
        # the connection.  IE and others send an extra \r\n after POSTs
        my $dummy = $self->read(5);
        
        # close if we have no response headers or they say to close
        $self->close("no_keep_alive");
        return 0;
    }

    # if they just did a POST, set the flag that says we might expect
    # an unadvertised \r\n coming from some browsers.  Old Netscape
    # 4.x did this on all POSTs, and Firefox/Safari do it on
    # XmlHttpRequest POSTs.
    if ($self->{headers_in}->request_method eq "POST") {
        $self->{ditch_leading_rn} = 1;
    }

    # now since we're doing persistence, uncork so the last packet goes.
    # we will recork when we're processing a new request.
    # TODO: Disabled because this seemed mostly relevant to Perlbal...
    #$self->tcp_cork(0);

    # reset state
    $self->{alive_time}            = $self->{create_time} = time;
    $self->{headers_string}        = '';
    $self->{headers_in}            = undef;
    $self->{headers_out}           = undef;
    $self->{http_headers_sent}     = 0;
    
    # NOTE: because we only speak 1.0 to clients they can't have
    # pipeline in a read that we haven't read yet.
    $self->watch_read(1);
    $self->watch_write(0);
    return 1;
}

sub DESTROY {
#    print "Connection DESTROY\n";
}

# Cleanup routine to get rid of timed out sockets
sub _do_cleanup {
    my $now = time;
    
    # AxKit2::Client->log(LOGDEBUG, "do cleanup");
    
    Danga::Socket->AddTimer(CLEANUP_TIME, \&_do_cleanup);
    
    my $sf = __PACKAGE__->get_sock_ref;
    
    my $conns = 0;

    my %max_age;  # classname -> max age (0 means forever)
    my %max_connect; # classname -> max connect time
    my @to_close;
    while (my $k = each %$sf) {
        my AxKit2::Connection $v = $sf->{$k};
        my $ref = ref $v;
        next unless $v->isa('AxKit2::Connection');
        $conns++;
        unless (defined $max_age{$ref}) {
            $max_age{$ref}      = $ref->max_idle_time || 0;
            $max_connect{$ref}  = $ref->max_connect_time || 0;
        }
        if (my $t = $max_connect{$ref}) {
            if ($v->{create_time} < $now - $t) {
                push @to_close, $v;
                next;
            }
        }
        if (my $t = $max_age{$ref}) {
            if ($v->{alive_time} < $now - $t) {
                push @to_close, $v;
            }
        }
    }
    
    $_->close("Timeout") foreach @to_close;
}

1;
