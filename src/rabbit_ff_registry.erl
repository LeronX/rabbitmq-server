%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2018 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_ff_registry).

-export([get/1,
         list/1,
         is_supported/1,
         is_enabled/1,
         is_registry_initialized/0,
         is_registry_written_to_disk/0]).

-spec get(rabbit_feature_flags:feature_name()) ->
    rabbit_feature_flags:feature_props() | undefined.

get(Arg) ->
    rabbit_feature_flags:initialize_registry(),
    %% Initially, is_registry_initialized/0 always returns `false` and
    %% this ?MODULE:get(Arg) is always called. The case statement is
    %% here to please Dialyzer.
    case is_registry_initialized() of
        false -> ?MODULE:get(Arg);
        true  -> undefined
    end.

-spec list(all | enabled | disabled) -> rabbit_feature_flags:feature_flags().

list(Arg) ->
    rabbit_feature_flags:initialize_registry(),
    %% See get/1 for an explanation of the case statement below.
    case is_registry_initialized() of
        false -> ?MODULE:list(Arg);
        true  -> #{}
    end.

-spec is_supported(rabbit_feature_flags:feature_name()) -> boolean().

is_supported(Arg) ->
    rabbit_feature_flags:initialize_registry(),
    %% See get/1 for an explanation of the case statement below.
    case is_registry_initialized() of
        false -> ?MODULE:is_supported(Arg);
        true  -> false
    end.

-spec is_enabled(rabbit_feature_flags:feature_name()) -> boolean() | state_changing.

is_enabled(Arg) ->
    rabbit_feature_flags:initialize_registry(),
    %% See get/1 for an explanation of the case statement below.
    case is_registry_initialized() of
        false -> ?MODULE:is_enabled(Arg);
        true  -> false
    end.

-spec is_registry_initialized() -> boolean().

is_registry_initialized() ->
    always_return_false().

-spec is_registry_written_to_disk() -> boolean().

is_registry_written_to_disk() ->
    always_return_true().

always_return_true() ->
    %% This function is here to trick Dialyzer. We want some functions
    %% in this initial on-disk registry to always return `true` or
    %% `false`. However the generated regsitry will return actual
    %% booleans. The `-spec()` correctly advertises a return type of
    %% `boolean()`. But in the meantime, Dialyzer only knows about this
    %% copy which, without the trick below, would always return either
    %% `true` (e.g. in is_registry_written_to_disk/0) or `false` (e.g.
    %% is_registry_initialized/0). This obviously causes some warnings
    %% where the registry functions are used: Dialyzer believes that
    %% e.g. matching the return value of is_registry_initialized/0
    %% against `true` will never succeed.
    %%
    %% That's why this function makes a call which we know the result,
    %% but not Dialyzer, to "create" that hard-coded `true` return
    %% value.
    rand:uniform(1) =/= 1.

always_return_false() ->
    not always_return_true().
