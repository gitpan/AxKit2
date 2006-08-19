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

package AxKit2::Client;

use strict;
use warnings;

use AxKit2::Plugin;
use AxKit2::Constants;

our %PLUGINS;

sub load_plugin {
    my ($class, $conf, $plugin) = @_;
    
    my $package;
    
    if ($plugin =~ m/::/) {
        # "full" package plugin (My::Plugin)
        $package = $plugin;
        $package =~ s/[^_a-z0-9:]+//gi;
        my $eval = qq[require $package;\n] 
                  .qq[sub ${plugin}::plugin_name { '$plugin' }]
                  .qq[sub ${plugin}::hook_name { shift->{_hook}; }];
        $eval =~ m/(.*)/s;
        $eval = $1;
        eval $eval;
        die "Failed loading $package - eval $@" if $@;
        $class->log(LOGDEBUG, "Loaded Plugin $package");
    }
    else {
        
        my $dir = $conf->plugin_dir || "./plugins";
        
        my $plugin_name = plugin_to_name($plugin);
        $package = "AxKit2::Plugin::$plugin_name";
        
        # don't reload plugins if they are already loaded
        unless ( defined &{"${package}::plugin_name"} ) {
            AxKit2::Plugin->_compile($plugin_name,
                $package, "$dir/$plugin");
        }
    }
    
    return if $PLUGINS{$plugin};
    
    my $plug = $package->new();
    $PLUGINS{$plugin} = $plug;
    $plug->_register();
}

sub plugin_to_name {
    my $plugin = shift;
    
    my $plugin_name = $plugin;
    
    # Escape everything into valid perl identifiers
    $plugin_name =~ s/([^A-Za-z0-9_\/])/sprintf("_%2x",unpack("C",$1))/eg;

    # second pass cares for slashes and words starting with a digit
    $plugin_name =~ s{
              (/+)       # directory
              (\d?)      # package's first character
             }[
               "::" . (length $2 ? sprintf("_%2x",unpack("C",$2)) : "")
              ]egx;

    
    return $plugin_name;
}

sub plugin_instance {
    my $plugin = shift;
    return $PLUGINS{$plugin};
}

sub config {
    # should be subclassed - clients get a server config
    AxKit2::Config->global;
}

sub run_hooks {
    my ($self, $hook) = (shift, shift);
    
    my $conf = $self->config();
    
    my @r;
  MAINLOOP:
    for my $plugin ($conf->plugins) {
        my $plug = plugin_instance($plugin) || next;
        for my $h ($plug->hooks($hook)) {
            $self->log(LOGDEBUG, "$plugin running hook $hook") unless $hook eq 'logging';
            eval { @r = $plug->$h($self, $conf, @_) };
            if ($@) {
                my $err = $@;
                $self->log(LOGERROR, "FATAL PLUGIN ERROR: $err");
                return SERVER_ERROR, $err;
            }
            next unless @r;
            last MAINLOOP unless $r[0] == DECLINED;
        }
    }
    $r[0] = DECLINED if not defined $r[0];
    return @r;
}

sub log {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('logging', @_);
}

sub hook_connect {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('connect');
    if ($ret == DECLINED) {
        return 1;
    }
    else {
        # TODO: Output some stuff...
        return;
    }
}

sub hook_uri_to_file {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('uri_translation', @_);
    if ($ret == DECLINED || $ret == OK) {
        return 1;
    }
    else {
        # TODO: output error stuff?
        return;
    }
}

sub hook_access_control {
    1;
}

sub hook_authentication {
    1;
}

sub hook_authorization {
    1;
}

sub hook_fixup {
    1;
}

sub hook_error {
    my $self = shift;
    $self->headers_out->code(SERVER_ERROR);
    my ($ret) = $self->run_hooks('error', @_);
    if ($ret != OK) {
        $self->headers_out->header('Content-Type' => 'text/html; charset=UTF-8');
        $self->send_http_headers;
        $self->write(<<EOT);
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<HTML><HEAD>
<TITLE>500 Internal Server Error</TITLE>
</HEAD><BODY>
<H1>Internal Server Error</H1>
The server encountered an internal error or
misconfiguration and was unable to complete
your request.<P>
More information about this error may be available
in the server error log.<P>
<HR>
</BODY></HTML>
EOT
    }
    else {
        # we assume some hook handled the error
    }
}

sub hook_xmlresponse {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('xmlresponse', @_);
    if ($ret == DECLINED) {
        return 0;
    }
    elsif ($ret == OK) {
        $out->output($self) if $out;
        return 1; # stop
    }
    elsif ($ret == SERVER_ERROR) {
        $self->hook_error($out);
        return 1; # stop
    }
    else {
        # TODO: handle errors
    }
}

sub hook_response {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('response', @_);
    if ($ret == DECLINED) {
        $self->headers_out->code(NOT_FOUND);
        $self->headers_out->header('Content-Type' => 'text/html; charset=UTF-8');
        $self->send_http_headers;
        my $uri = $self->headers_in->uri;
        $self->write(<<EOT);
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<HTML><HEAD>
<TITLE>404 Not Found</TITLE>
</HEAD><BODY>
<H1>Not Found</H1>
The requested URL $uri was not found on this server.<P>
<HR>
</BODY></HTML>
EOT
        return;
    }
    elsif ($ret == OK) {
        return 1;
    }
    elsif ($ret == SERVER_ERROR) {
        $self->hook_error($out);
        return 1; # stop
    }
    else {
        # TODO: output error stuff?
    }
}

sub hook_body_data {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('body_data', @_);
    if ($ret == DECLINED) {
        return;
    }
    if ($ret == DONE) {
        $self->process_request();
        return;
    }
    elsif ($ret == OK) {
        return 1;
    }
    else {
        # TODO: output error stuff?
    }
}

sub hook_mime_map {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('mime_map', @_);
    if ($ret == DECLINED) {
        return 1;
    }
    elsif ($ret == OK) {
        return 1;
    }
    else {
        # TODO: output error stuff?
    }
}

sub hook_response_sent {
    my $self = shift;
    my ($ret, $out) = $self->run_hooks('response_sent', @_);
    if ($ret == DONE) {
        return 1;
    }
    elsif ($ret == DECLINED || $ret == OK) {
        return;
    }
    else {
        # TODO: errors?
    }
}

1;
