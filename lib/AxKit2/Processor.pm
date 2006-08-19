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

package AxKit2::Processor;

use strict;
use warnings;

use Exporter ();

our @ISA = qw(Exporter);
our @EXPORT = qw(XSP XSLT TAL XPathScript);

use XML::LibXML;
use AxKit2::Transformer::XSP;

our $parser = XML::LibXML->new();

# ->new($path [, $input]);
sub new {
    my $class = shift; $class = ref($class) if ref($class);
    my $client = shift || die "A processor needs a client";
    my $path  = shift || die "A processor needs source document path";
    
    my $self = bless {client => $client, path => $path}, $class;
    
    @_ and $self->{input}  = shift;
    @_ and $self->{output} = shift;
    
    return $self;
}

sub path {
    my $self = shift;
    $self->{path};
}

sub input {
    my $self = shift;
    $self->{input};
}

sub client {
    my $self = shift;
    $self->{client};
}

sub dom {
    my $self = shift;
    @_ and $self->{input} = shift;
    
    my $input =    $self->{input} 
                || do { open(my $fh, $self->{path})
                     || die "open($self->{path}): $!";
                        die "open($self->{path}): directory" if -d $fh;
                        $fh };
    
    if (ref($input) eq 'XML::LibXML::Document') {
        return $input;
    }
    elsif (ref($input) eq 'GLOB') {
        # parse $fh
        return $self->{input} = $parser->parse_fh($input);
    }
    else {
        # assume string
        return $self->{input} = $parser->parse_string($input);
    }
}

sub output {
    my $self   = shift;
    my $client = shift;
    
    if ($self->{output}) {
        $self->{output}->($client, $self->dom);
    }
    else {
        my $out = $self->dom->toString;
        $client->headers_out->header('Content-Length', length($out));
        $client->headers_out->header('Content-Type', 'text/xml');
        $client->send_http_headers;
        $client->write($out);
    }
}

sub str_to_transform {
    my $str = shift;
    ref($str) and return $str;
    if ($str =~ /^(TAL|XSP|XSLT)\((.*)\)/) {
        return $1->($2);
    }
    else {
        die "Unknown transform type: $str";
    }
}

sub transform {
    my $self = shift;
    my @transforms = map { str_to_transform($_) } @_;
    
    my $pos = 0;
    my ($dom, $outfunc);
    for my $trans (@transforms) {
        $trans->client($self->client);
        if ($AxKit2::Processor::DumpIntermediate) {
            mkdir("/tmp/axtrace");
            open(my $fh, ">/tmp/axtrace/trace.$pos");
            print $fh ($dom || $self->dom)->toString;
        }
        ($dom, $outfunc) = $trans->transform($pos++, $self);
        # $trans->client(undef);
        $self->dom($dom);
    }
    
    return $self->new($self->client, $self->path, $dom, $outfunc);
}

sub XSP {
    die "XSP takes no arguments" if @_;
    return AxKit2::Transformer::XSP->new();
}

sub XSLT {
    my $stylesheet = shift || die "XSLT requires a stylesheet";
    require AxKit2::Transformer::XSLT;
    return AxKit2::Transformer::XSLT->new($stylesheet, @_);
}

sub TAL {
    my $stylesheet = shift || die "TAL requires a stylesheet";
    require AxKit2::Transformer::TAL;
    return AxKit2::Transformer::TAL->new($stylesheet);
}

sub XPathScript {
    my $stylesheet = shift || die "XPathScript requires a stylesheet";
    require AxKit2::Transformer::XPathScript;
    my $output_style = shift;
    return AxKit2::Transformer::XPathScript->new($stylesheet, $output_style);
}

1;
