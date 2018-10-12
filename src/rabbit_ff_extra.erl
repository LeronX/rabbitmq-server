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

-module(rabbit_ff_extra).

-export([cli_info/0,
         info/1,
         info/2]).

-type cli_info() :: [cli_info_entry()].
-type cli_info_entry() :: [{name, rabbit_feature_flags:feature_name()} |
                           {state, enabled | disabled | unavailable} |
                           {stability, rabbit_feature_flags:stability()} |
                           {provided_by, atom()} |
                           {desc, string()}].

-type info_options() :: #{color => boolean(),
                          lines => boolean(),
                          verbose => non_neg_integer()}.

-export_type([info_options/0]).

-spec cli_info() -> cli_info().

cli_info() ->
    cli_info(rabbit_feature_flags:list(all)).

-spec cli_info(rabbit_feature_flags:feature_flags()) -> cli_info().

cli_info(FeatureFlags) ->
    maps:fold(
      fun(FeatureName, FeatureProps, Acc) ->
              State = rabbit_feature_flags:get_state(FeatureName),
              Stability = rabbit_feature_flags:get_stability(FeatureProps),
              App = maps:get(provided_by, FeatureProps),
              Desc = maps:get(desc, FeatureProps, ""),
              FFInfo = [{name, FeatureName},
                        {desc, Desc},
                        {state, State},
                        {stability, Stability},
                        {provided_by, App}],
              [FFInfo | Acc]
      end, [], FeatureFlags).

-spec info(info_options()) -> ok.

info(Options) ->
    %% Two tables: one for stable feature flags, one for experimental ones.
    StableFF = rabbit_feature_flags:list(all, stable),
    case maps:size(StableFF) of
        0 ->
            ok;
        _ ->
            io:format("~n~s## Stable feature flags:~s~n",
                      [ascii_color(bright_white), ascii_color(default)]),
            info(StableFF, Options)
    end,
    ExpFF = rabbit_feature_flags:list(all, experimental),
    case maps:size(ExpFF) of
        0 ->
            ok;
        _ ->
            io:format("~n~s## Experimental feature flags:~s~n",
                      [ascii_color(bright_white), ascii_color(default)]),
            info(ExpFF, Options)
    end,
    case maps:size(StableFF) + maps:size(ExpFF) of
        0 -> ok;
        _ -> state_legend()
    end.

-spec info(rabbit_feature_flags:feature_flags(), info_options()) -> ok.

info(FeatureFlags, Options) ->
    Verbose = maps:get(verbose, Options, 0),
    IsaTty= case os:getenv("TERM") of
                %% We don't have access to isatty(3), so let's
                %% assume that is $TERM is defined, we can use
                %% colors and drawing characters.
                false -> false;
                _     -> true
            end,
    UseColors = maps:get(color, Options, IsaTty),
    UseLines = maps:get(lines, Options, IsaTty),
    %% Table columns:
    %%     | Name | State | Provided by | Description
    %%
    %% where:
    %%     State = Enabled | Disabled | Unavailable (if a node doesn't
    %%     support it).
    TableHeader = [
                   [{"Name", bright_white},
                    {"State", bright_white},
                    {"Provided by", bright_white},
                    {"Description", bright_white}]
                  ],
    Nodes = lists:sort([node() | rabbit_feature_flags:remote_nodes()]),
    Rows = maps:fold(
             fun(FeatureName, FeatureProps, Acc) ->
                     State0 = rabbit_feature_flags:get_state(FeatureName),
                     {State, StateColor} = case State0 of
                                               enabled ->
                                                   {"Enabled", green};
                                               disabled ->
                                                   {"Disabled", yellow};
                                               unavailable ->
                                                   {"Unavailable", red_bg}
                                           end,
                     App = maps:get(provided_by, FeatureProps),
                     Desc = maps:get(desc, FeatureProps, ""),
                     MainLine = [{atom_to_list(FeatureName), bright_white},
                                 {State, StateColor},
                                 {atom_to_list(App), default},
                                 {Desc, default}],
                     VFun = fun(Node) ->
                                    Supported =
                                    rabbit_feature_flags:does_node_support(
                                      Node, [FeatureName], 60000),
                                    {Label, LabelColor} =
                                    case Supported of
                                        true  -> {"supported", default};
                                        false -> {"unsupported", red_bg}
                                    end,
                                    Uncolored = rabbit_misc:format(
                                                  "  ~s: ~s", [Node, Label]),
                                    Colored = rabbit_misc:format(
                                                "  ~s: ~s~s~s",
                                                [Node,
                                                 ascii_color(LabelColor),
                                                 Label,
                                                 ascii_color(default)]),
                                    [empty,
                                     empty,
                                     empty,
                                     {Uncolored, Colored}]
                            end,
                     if
                         Verbose > 0 ->
                             [[MainLine,
                               empty,
                               [empty,
                                empty,
                                empty,
                                {"Per-node support level:", default}]
                               | lists:map(VFun, Nodes)] | Acc];
                         true ->
                             [[MainLine] | Acc]
                     end
             end, [], FeatureFlags),
    display_table([TableHeader | Rows], UseColors, UseLines).

display_table([[FirstLine | _] | _] = Rows, UseColors, UseLines) ->
    %% Compute columns width.
    ColsCount = length(FirstLine),
    ColsWidths = lists:foldl(
                   fun(Row, Acc1) ->
                           lists:foldl(
                             fun
                                 (empty, Acc2) ->
                                     Acc2;
                                 (Line, Acc2) ->
                                     lists:foldl(
                                       fun(Col, Acc3) ->
                                               MaxW = lists:nth(Col, Acc2),
                                               case lists:nth(Col, Line) of
                                                   empty ->
                                                       [MaxW | Acc3];
                                                   {Txt, _} ->
                                                       CurW =
                                                       string:length(Txt),
                                                       case CurW > MaxW of
                                                           true ->
                                                               [CurW | Acc3];
                                                           false ->
                                                               [MaxW | Acc3]
                                                       end
                                               end
                                       end,
                                       [], lists:seq(ColsCount, 1, -1))
                             end,
                             Acc1, Row)
                   end,
                   lists:duplicate(ColsCount, 0), Rows),
    %% Prepare format string used for the content.
    VerticalSep = case UseLines of
                      true  -> "\x1b(0x\x1b(B";
                      false -> "|"
                  end,
    FormatString = rabbit_misc:format(
                     "~s ~s ~s~n",
                     [VerticalSep,
                      lists:join(
                        " " ++ VerticalSep ++ " ",
                        lists:duplicate(ColsCount, "~s~s~s~s")),
                      VerticalSep]),
    %% Prepare borders (top, middle, bottom).
    TopBorder = case UseLines of
                    true ->
                        rabbit_misc:format(
                          "\x1b(0lq~sqk\x1b(B",
                          [lists:join(
                             "qwq",
                             lists:map(
                               fun(ColW) -> string:chars($q, ColW) end,
                               ColsWidths))]);
                    false ->
                        rabbit_misc:format(
                          "+-~s-+",
                          [lists:join(
                             "-+-",
                             lists:map(
                               fun(ColW) -> string:chars($-, ColW) end,
                               ColsWidths))])
                end,
    MiddleBorder = case UseLines of
                       true ->
                           rabbit_misc:format(
                             "\x1b(0tq~squ\x1b(B",
                             [lists:join(
                                "qnq",
                                lists:map(
                                  fun(ColW) -> string:chars($q, ColW) end,
                                  ColsWidths))]);
                       false ->
                           TopBorder
                   end,
    BottomBorder = case UseLines of
                       true ->
                           rabbit_misc:format(
                             "\x1b(0mq~sqj\x1b(B",
                             [lists:join(
                                "qvq",
                                lists:map(
                                  fun(ColW) -> string:chars($q, ColW) end,
                                  ColsWidths))]);
                       false ->
                           TopBorder
                   end,
    io:format("~n~s~n", [TopBorder]),
    display_rows(Rows, ColsWidths, FormatString, UseColors, MiddleBorder),
    io:format("~s~n", [BottomBorder]).

display_rows([Row | Rest],
             ColsWidths, FormatString, UseColors, MiddleBorder) ->
    lists:foreach(
      fun(Line) ->
              io:format(
                FormatString,
                lists:append(
                  lists:map(
                    fun(Col) ->
                            Line1 = case Line of
                                        empty ->
                                            lists:duplicate(
                                              length(ColsWidths), empty);
                                        _ ->
                                            Line
                                    end,
                            {Value, Color} = case lists:nth(Col, Line1) of
                                                 empty  -> {"", ""};
                                                 {V, C} -> {V, C}
                                             end,
                            ColW = lists:nth(Col, ColsWidths),
                            PaddingLen = ColW - string:length(Value),
                            Padding = string:chars($\s, PaddingLen),
                            case is_atom(Color) of
                                true ->
                                    [ascii_color(Color),
                                     Value,
                                     ascii_color(default),
                                     Padding];
                                false ->
                                    ["",
                                     Color,
                                     "",
                                     Padding]
                            end
                    end,
                    lists:seq(1, length(ColsWidths)))))
      end,
      Row),
    case Rest of
        [] -> ok;
        _  -> io:format("~s~n", [MiddleBorder])
    end,
    display_rows(Rest, ColsWidths, FormatString, UseColors, MiddleBorder);
display_rows([], _, _, _, _) ->
    ok.

state_legend() ->
    io:format(
      "~n"
      "Possible states:~n"
      "      ~sEnabled~s: The feature flag is enabled on all nodes~n"
      "     ~sDisabled~s: The feature flag is disabled on all nodes~n"
      "  ~sUnavailable~s: The feature flag cannot be enabled because one or more nodes do not support it~n"
      "~n",
      [ascii_color(green), ascii_color(default),
       ascii_color(yellow), ascii_color(default),
       ascii_color(red_bg), ascii_color(default)]).

-type color() :: default | bright_white | red_bg | green | yellow.

-spec ascii_color(color()) -> string().

ascii_color(default)      -> "\033[0m";
ascii_color(bright_white) -> "\033[1m";
ascii_color(red_bg)       -> "\033[1;37;41m";
ascii_color(green)        -> "\033[32m";
ascii_color(yellow)       -> "\033[33m".
