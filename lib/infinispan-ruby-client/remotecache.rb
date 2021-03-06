#
# Copyright 2011 Red Hat, Inc.
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

require 'socket'

module Infinispan
  class RemoteCache
    include Infinispan::Constants

    attr_accessor :host, :port, :name

    def initialize( host="localhost", port=11222, name="" )
      @host = host
      @port = port
      @name = name
    end

    def ping
      do_op( :operation => PING[0] )
    end

    def clear
      do_op( :operation => CLEAR[0] )
    end

    def get( key )
      do_op( :operation => GET[0], :key => key )
    end

    def get_bulk( count = 0 )
      do_op( :operation => BULK_GET[0], :count => count )
    end
    
    def put( key, value )
      do_op( :operation => PUT[0], :key => key, :value => value )
    end

    def put_if_absent( key, value )
      do_op( :operation => PUT_IF_ABSENT[0], :key => key, :value => value )
    end

    def get_versioned( key )
      do_op( :operation => GET_WITH_VERSION[0], :key => key )
    end

    def contains_key?( key )
      do_op( :operation => CONTAINS[0], :key => key )
    end

    alias_method :contains_key, :contains_key?

    def remove( key )
      do_op( :operation => REMOVE[0], :key => key )
    end

    def remove_if_unmodified( key, version )
      do_op( :operation => REMOVE_IF[0], :key => key, :version => version )
    end

    def replace( key, value )
      do_op( :operation => REPLACE[0], :key => key, :value => value )
    end

    def replace_if_unmodified( key, version, value )
      do_op( :operation => REPLACE_IF[0], :key => key, :value => value, :version => version )
    end

    private
    def do_op( options )
      options[:cache] ||= @name

      send_op    = Operation.send[ options[:operation] ]
      recv_op    = Operation.receive[ options[:operation] ]

      if (send_op && recv_op)
        TCPSocket.open( @host, @port ) do |connection|
          send_op.call( connection, options )
          recv_op.call( connection )
        end
      else
        raise "Unexpected operation: #{options[:operation]}"
      end

    end
  end

  module Operation

    include Infinispan::Constants
    include Infinispan::ResponseCode

    def self.send 
      {
        GET[0]                      => KEY_ONLY_SEND,
        GET_WITH_VERSION[0]         => KEY_ONLY_SEND,
        BULK_GET[0]                 => BULK_GET_SEND,
        PUT[0]                      => KEY_VALUE_SEND,
        REMOVE[0]                   => KEY_ONLY_SEND,
        REMOVE_IF[0]                => REMOVE_IF_SEND,
        CONTAINS[0]                 => KEY_ONLY_SEND,
        PUT_IF_ABSENT[0]            => KEY_VALUE_SEND,
        REPLACE[0]                  => KEY_VALUE_SEND,
        REPLACE_IF[0]               => REPLACE_IF_SEND,
        CLEAR[0]                    => HEADER_ONLY_SEND,
        PING[0]                     => HEADER_ONLY_SEND
      }
    end

    def self.receive 
      {
        GET[0]                      => KEY_ONLY_RECV,
        GET_WITH_VERSION[0]         => GET_WITH_VERSION_RECV,
        BULK_GET[0]                 => BULK_GET_RECV,
        PUT[0]                      => BASIC_RECV,
        REMOVE[0]                   => BASIC_RECV,
        REMOVE_IF[0]                => BASIC_RECV,
        CONTAINS[0]                 => BASIC_RECV,
        PUT_IF_ABSENT[0]            => BASIC_RECV,
        REPLACE[0]                  => BASIC_RECV,
        REPLACE_IF[0]               => BASIC_RECV,
        CLEAR[0]                    => BASIC_RECV,
        PING[0]                     => BASIC_RECV
      }
    end

    HEADER_ONLY_SEND = lambda { |connection, options|
      connection.write( HeaderBuilder.getHeader(options[:operation], options[:cache]) )
    }

    BULK_GET_SEND = lambda { |connection, options|
      connection.write( HeaderBuilder.getHeader(options[:operation], options[:cache]) )
      connection.write( Unsigned.encodeVint( options[:count] ) )
    }

    KEY_ONLY_SEND = lambda { |connection, options|
      connection.write( HeaderBuilder.getHeader(options[:operation], options[:cache]) )
      mkey = Marshal.dump( options[:key] )
      connection.write( Unsigned.encodeVint( mkey.size ) )
      connection.write( mkey )
    }

    KEY_VALUE_SEND = lambda { |connection, options|
      connection.write( HeaderBuilder.getHeader(options[:operation], options[:cache]) )
      # write key
      mkey = Marshal.dump( options[:key] )
      connection.write( Unsigned.encodeVint( mkey.size ) )
      connection.write( mkey )

      # lifespan + max_idle (not supported yet)
      connection.write( [0x00.chr,0x00.chr] )

      # write value
      mkey = Marshal.dump( options[:value] )
      connection.write( Unsigned.encodeVint( mkey.size ) )
      connection.write( mkey )
    }

    REMOVE_IF_SEND = lambda { |connection, options|
      connection.write( HeaderBuilder.getHeader(options[:operation], options[:cache]) )

      # write key
      key = Marshal.dump( options[:key] )
      connection.write( Unsigned.encodeVint( key.size ) )
      connection.write( key )

      # write version
      connection.write( options[:version] )
    }

    REPLACE_IF_SEND = lambda { |connection, options|
      connection.write( HeaderBuilder.getHeader(options[:operation], options[:cache]) )

      # write key
      key = Marshal.dump( options[:key] )
      connection.write( Unsigned.encodeVint( key.size ) )
      connection.write( key )

      # lifespan + max_idle (not supported yet)
      connection.write( [0x00.chr,0x00.chr] )

      # write version
      connection.write( options[:version] )

      # write value
      value = Marshal.dump( options[:value] )
      connection.write( Unsigned.encodeVint( value.size ) )
      connection.write( value )
    }

    KEY_ONLY_RECV = lambda { |connection|
      connection.read( 5 ) # The response header
      response_body_length = Unsigned.decodeVint( connection )
      response_body = connection.read( response_body_length )
      Marshal.load( response_body )
    }

    GET_WITH_VERSION_RECV = lambda { |connection|
      response_header = connection.read( 5 ) # The response header
      version = connection.read( 8 )
      response_body_length = Unsigned.decodeVint( connection )
      response_body = connection.read( response_body_length )
      [ version, Marshal.load( response_body ) ]
    }

    BULK_GET_RECV = lambda { |connection|
      response = {}
      response_header = connection.read( 5 ) # The response header
      more = connection.read(1).unpack('c')[0]
      while (more == 1) # The "more" flag
        key_length = Unsigned.decodeVint( connection )
        key = connection.read( key_length )
        value_length = Unsigned.decodeVint( connection )
        value = connection.read( value_length )
        response[Marshal.load(key)] = Marshal.load(value)
        more = connection.read(1).unpack('c')[0]
      end
      response
    }

    BASIC_RECV = lambda { |connection|
      header = connection.read( 5 ) # Just the response header
      header[3] == SUCCESS
    }

  end
end
