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

package AxKit2::Config;

# API for configuration - implement in a subclass

use strict;
use warnings;

use AxKit2::Client;
use AxKit2::Config::Global;
use AxKit2::Config::Server;
use AxKit2::Config::Location;

our %CONFIG = (
    Plugin => [\&TAKE1, sub { my $conf = shift; AxKit2::Client->load_plugin($conf, $_[0]); $conf->add_plugin($_[0]); }],
    Port   => [\&TAKE1, sub { my $conf = shift; $conf->port($_[0]) }],
    DocumentRoot => [\&TAKE1, sub { my $conf = shift; $conf->docroot($_[0]) }],
    ConsolePort => [\&TAKE1, sub { my $conf = shift; $conf->isa('AxKit2::Config::Global') || die "ConsolePort only allowed at global level"; $conf->console_port($_[0]) }],
    ConsoleAddr => [\&TAKE1, sub { my $conf = shift; $conf->isa('AxKit2::Config::Global') || die "ConsoleAddr only allowed at global level"; $conf->console_addr($_[0]) }],
    PluginDir  => [\&TAKE1, sub { my $conf = shift; $conf->plugin_dir($_[0]) }],
    );

our $GLOBAL = AxKit2::Config::Global->new();

sub new {
    my ($class, $file) = @_;
    
    my $self = bless {
            servers => [],
        }, $class;
    
    $self->parse_config($file);
    
    return $self;
}

sub global {
    return $GLOBAL;
}

sub add_config_param {
    my $class = shift;
    my $key = shift || die "add_config_param() requires a key";
    my $validate = shift || die "add_config_param() requires a validate routine";
    my $store = shift || die "add_config_param() requires a store routine";
    
    if (exists $CONFIG{$key}) {
        die "Config key '$key' already exists";
    }
    $CONFIG{$key} = [$validate, $store];
}

sub servers {
    my $self = shift;
    return @{$self->{servers}};
}

sub parse_config {
    my ($self, $file) = @_;
    
    open(my $fh, $file) || die "open($file): $!";
    local $self->{_fh} = $fh;
    
    my $global = $self->global;
    while ($self->_configline) {
        if (/^<Server(\s*(\S*))>/i) {
            my $name = $2 || "";
            $self->_parse_server($global, $name);
            next;
        }
        _generic_config($global, $_);
    }
}

sub _parse_server {
    my ($self, $global, $name) = @_;
    
    my $server = AxKit2::Config::Server->new($global, $name);
    
    my $closing = 0;
    while ($self->_configline) {
        if (/^<Location\s+(\S.*)>/i) {
            my $path = $1;
            my $loc = $self->_parse_location($server, $path);
            $server->add_location($loc);
            next;
        }
        elsif (/<\/Server>/i) { $closing++; last; }
        _generic_config($server, $_);
    }
    
    my $forserver = $name ? "for server named $name " : "";
    die "No </Server> line ${forserver}in config file" unless $closing;
    
    push @{$self->{servers}}, $server;
    
    return;
}

sub _parse_location {
    my ($self, $server, $path) = @_;
    
    my $location = AxKit2::Config::Location->new($server, $path);

    my $closing = 0;
    while ($self->_configline) {
        if (/<\/Location>/i) { $closing++; last; }
        _generic_config($location, $_);
    }
    
    die "No </Location> line for path: $path in config file" unless $closing;
    
    return $location;
}

sub _generic_config {
    my ($conf, $line) = @_;
    my ($key, $rest) = split(/\s+/, $line, 2);
    if (!exists($CONFIG{$key})) {
        die "Invalid line in server config: $line";
    }
    my $cfg = $CONFIG{$key};
    my @vals = $cfg->[0]->($rest); # validate and clean
    $cfg->[1]->($conf, @vals);   # save value(s)
    return;
}

sub _configline {
    my $self = shift;
    die "No filehandle!" unless $self->{_fh};
    
    while ($_ = $self->{_fh}->getline) {
        return unless defined $_;
    
        next unless /\S/;
        # skip comments
        next if /^\s*#/;
        
        # cleanup whitespace
        s/^\s*//; s/\s*$//;
        
        chomp;
        
        if (s/\\$//) {
            # continuation line...
            my $line = $_;
            $_ = $line . $self->_configline;
        }
        
        return $_;
    }
}

sub _get_quoted {
    my $line = shift;
    
    my $out = '';
    $line =~ s/^"//;
    while ($line =~ /\G(.*?)([\\\"])/gc) {
        $out .= $1;
        my $token = $2;
        if ($token eq "\\") {
            $line =~ /\G([\"\\])/gc || die "invalid escape char";
            $out .= $1;
        }
        elsif ($token eq '"') {
            $line =~ /\G\s*(.*)$/gc;
            return $out, $1;
        }
    }
    die "Invalid quoted string";
}

sub TAKE1 {
    my $str = shift;
    my @vals = TAKEMANY($str);
    if (@vals != 1) {
        die "Invalid number of params";
    }
    return $vals[0];
}

sub TAKEMANY {
    my $str = shift;
    my @vals;
    while (length($str)) {
        if ($str =~ /^"/) {
            my $val;
            ($val, $str) = _get_quoted($str);
            push @vals, $val;
        }
        else {
            $str =~ s/^(\S+)\s*// || die "bad format";
            push @vals, $1;
        }
    }
    die "No data found" unless @vals;
    return @vals;
}

1;
