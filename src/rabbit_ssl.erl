%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_ssl).

-include("rabbit.hrl").

-include_lib("public_key/include/public_key.hrl").
-include_lib("ssl/src/ssl_int.hrl").

-export([ssl_issuer/1, ssl_subject/1, ssl_validity/1]).

-export_type([certificate/0, ssl_socket/0]).

%%--------------------------------------------------------------------------

-ifdef(use_specs).

-type(ssl_socket() :: #ssl_socket{}).
-type(certificate() :: #'OTPCertificate'{}).
-type(a_socket() :: rabbit_networking:socket() | ssl_socket()).

-spec(ssl_issuer/1 :: (a_socket()) -> string()).
-spec(ssl_subject/1 :: (a_socket()) -> string()).
-spec(ssl_validity/1 :: (a_socket()) -> string()).

-endif. %% use_specs


%%--------------------------------------------------------------------------
%% High-level functions used by reader
%%--------------------------------------------------------------------------

%% Return a string describing the certificate's issuer.
ssl_issuer(Sock) ->
    ssl_info(fun(#'OTPCertificate' {
                    tbsCertificate = #'OTPTBSCertificate' {
                      issuer = Issuer }}) ->
                     format_rdn_sequence(Issuer)
             end, Sock).

%% Return a string describing the certificate's subject, as per RFC4514.
ssl_subject(Sock) ->
    ssl_info(fun(#'OTPCertificate' {
                    tbsCertificate = #'OTPTBSCertificate' {
                      subject = Subject }}) ->
                     format_rdn_sequence(Subject)
             end, Sock).

%% Return a string describing the certificate's validity.
ssl_validity(Sock) ->
    ssl_info(fun(#'OTPCertificate' {
                    tbsCertificate = #'OTPTBSCertificate' {
                      validity = {'Validity', Start, End} }}) ->
                     lists:flatten(
                       io_lib:format("~s-~s", [format_ssl_value(Start),
                                               format_ssl_value(End)]))
             end, Sock).

%% Wrapper for applying a function to a socket's certificate.
ssl_info(F, Sock) ->
    case rabbit_net:peercert(Sock) of
        {error, no_peercert} -> no_peer_certificate;
        {error, E}           -> rabbit_log:warning("Error getting cert: ~p~n", [E]),
                                no_peer_certificate;
        nossl                -> nossl;
        {ok, Cert}           ->
            case public_key:pkix_decode_cert(Cert, otp) of
                {ok, DecCert} ->
                    try F(DecCert)  %% here be dragons; decompose an undocumented
                                    %% structure
                    catch
                        C:E ->
                            rabbit_log:info("Problems while processing SSL info: ~p:~p~n",
                                            [C, E]),
                            unknown
                    end;
                {error, E} ->
                    rabbit_log:warning("Error decoding cert: ~p~n", [E]),
                    no_peer_certificate
            end
    end.


%%--------------------------------------------------------------------------
%% Formatting functions
%%--------------------------------------------------------------------------

%% Format and rdnSequence as a RFC4514 subject string.
format_rdn_sequence({rdnSequence, Seq}) ->
    lists:flatten(
      rabbit_misc:intersperse(
        ",", lists:reverse(
               [escape_ssl_string(format_complex_rdn(RDN), start)
                || RDN <- Seq]))).

%% Escape a string as per RFC4514.
escape_ssl_string([], _) ->
    [];
escape_ssl_string([$  | S], start) ->
    ["\\ " | escape_ssl_string(S, start)];
escape_ssl_string([$# | S], start) ->
    ["\\#" | escape_ssl_string(S, start)];
escape_ssl_string(S, start) ->
    escape_ssl_string(S, middle);
escape_ssl_string([$  | S], middle) ->
    case lists:filter(fun(C) -> C =/= $  end, S) of
        []    -> escape_ssl_string([$  | S], ending);
        [_|_] -> [" " | escape_ssl_string(S, middle)]
    end;
escape_ssl_string([C | S], middle) ->
    case lists:member(C, ",+\"\\<>;") of
        false -> [C | escape_ssl_string(S, middle)];
        true  -> ["\\", C | escape_ssl_string(S, middle)]
    end;
escape_ssl_string([$  | S], ending) ->
    ["\\ " | escape_ssl_string(S, ending)].

%% Format an RDN set.
format_complex_rdn(RDNs) ->
    lists:flatten(rabbit_misc:intersperse("+", [format_rdn(RDN) || RDN <- RDNs])).

%% Format an RDN.  If the type name is unknown, use the dotted decimal
%% representation.  See RFC4514, section 2.3.
format_rdn(#'AttributeTypeAndValue'{type = T, value = V}) ->
    FV = format_ssl_value(V),
    Fmts = [{?'id-at-surname'                , "SN"},
            {?'id-at-givenName'              , "GIVENNAME"},
            {?'id-at-initials'               , "INITIALS"},
            {?'id-at-generationQualifier'    , "GENERATIONQUALIFIER"},
            {?'id-at-commonName'             , "CN"},
            {?'id-at-localityName'           , "L"},
            {?'id-at-stateOrProvinceName'    , "ST"},
            {?'id-at-organizationName'       , "O"},
            {?'id-at-organizationalUnitName' , "OU"},
            {?'id-at-title'                  , "TITLE"},
            {?'id-at-countryName'            , "C"},
            {?'id-at-serialNumber'           , "SERIALNUMBER"},
            {?'id-at-pseudonym'              , "PSEUDONYM"},
            {?'id-domainComponent'           , "DC"},
            {?'id-emailAddress'              , "EMAILADDRESS"},
            {?'street-address'               , "STREET"}],
    case proplists:lookup(T, Fmts) of
        {_, Fmt} ->
            io_lib:format(Fmt ++ "=~s", [FV]);
        none when is_tuple(T) ->
            TypeL = [io_lib:format("~w", [X]) || X <- tuple_to_list(T)],
            io_lib:format("~s:~s", [rabbit_misc:intersperse(".", TypeL), FV]);
        none ->
            io_lib:format("~p:~s", [T, FV])
    end.

%% Get the string representation of an OTPCertificate field.
format_ssl_value({printableString, S}) ->
    S;
format_ssl_value({utf8String, Bin}) ->
    binary_to_list(Bin);
format_ssl_value({utcTime, [Y1, Y2, M1, M2, D1, D2, H1, H2,
                            Min1, Min2, S1, S2, $Z]}) ->
    io_lib:format("20~c~c-~c~c-~c~cT~c~c:~c~c:~c~cZ",
                  [Y1, Y2, M1, M2, D1, D2, H1, H2, Min1, Min2, S1, S2]);
format_ssl_value(V) ->
    io_lib:format("~p", [V]).
