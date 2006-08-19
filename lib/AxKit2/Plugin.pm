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

package AxKit2::Plugin;

use strict;
use warnings;

use AxKit2::Config;
use AxKit2::Constants;

# more or less in the order they will fire
# DON'T FORGET - edit "AVAILABLE HOOKS" below.
our @hooks = qw(
    logging connect post_read_request body_data uri_translation access_control
    authentication authorization mime_map xmlresponse response
    response_sent disconnect error
);
our %hooks = map { $_ => 1 } @hooks;

sub new {
  my $proto = shift;
  my $class = ref($proto) || $proto;
  bless ({}, $class);
}

sub register_hook {
    my ($self, $hook, $method, $unshift) = @_;
    
    $self->log(LOGDEBUG, "register_hook: $hook => $method");
    die $self->plugin_name . " : Invalid hook: $hook" unless $hooks{$hook};
    
    push @{$self->{__hooks}{$hook}}, sub {
        my $self = shift;
        local $self->{_hook} = $hook;
        local $self->{_client} = shift;
        local $self->{_config} = shift;
        $self->$method(@_);
    };
}

sub register_config {
    my ($self, $key, $store) = @_;
    
    AxKit2::Config->add_config_param($key, \&AxKit2::Config::TAKEMANY, $store);
}

sub _register {
    my $self = shift;
    $self->init();
    $self->_register_standard_hooks();
    $self->register();
}

sub init {
    # implement in plugin
}

sub register {
    # implement in plugin
}

sub config {
    my $self = shift;
    $self->{_config};
}

sub client {
    my $self = shift;
    $self->{_client} || "AxKit2::Client";
}

sub log {
    my $self = shift;
    my $level = shift;
    my ($package) = caller;
    if ($package eq __PACKAGE__ || !defined $self->{_hook}) {
        $self->client->log($level, $self->plugin_name, " ", @_);
    }
    else {
        $self->client->log($level, $self->plugin_name, " $self->{_hook} ", @_);
    }
}

sub _register_standard_hooks {
    my $self = shift;
    
    for my $hook (@hooks) {
        my $hooksub = "hook_$hook";
        $hooksub  =~ s/\W/_/g;
        $self->register_hook( $hook, $hooksub ) if ($self->can($hooksub));
    }
}

sub hooks {
    my $self = shift;
    my $hook = shift;
    
    return $self->{__hooks}{$hook} ? @{$self->{__hooks}{$hook}} : ();
}

sub _compile {
    my ($class, $plugin, $package, $file) = @_;
    
    my $sub;
    open F, $file or die "could not open $file: $!";
    { 
      local $/ = undef;
      $sub = <F>;
    }
    close F;

    my $line = "\n#line 0 $file\n";

    my $eval = join(
		    "\n",
		    "package $package;",
		    'use AxKit2::Constants;',
		    'use AxKit2::Processor;',
		    "require AxKit2::Plugin;",
		    'use vars qw(@ISA);',
                    'use strict;',
		    '@ISA = qw(AxKit2::Plugin);',
		    "sub plugin_name { qq[$plugin] }",
		    "sub hook_name { return shift->{_hook}; }",
		    $line,
		    $sub,
		    "\n", # last line comment without newline?
		   );

    #warn "eval: $eval";

    $eval =~ m/(.*)/s;
    $eval = $1;

    eval $eval;
    die "eval $@" if $@;
}

1;

__END__

=head1 NAME

AxKit2::Plugin - base class for all plugins

=head1 DESCRIPTION

=head1 AVAILABLE HOOKS

=head2 logging

=head2 connect

=head2 post_read_request

=head2 body_data

=head2 uri_translation

=head2 access_control

=head2 authentication

=head2 authorization

=head2 mime_map

=head2 xmlresponse

=head2 response

=head2 response_sent

=head2 disconnect

=head2 error

=cut
