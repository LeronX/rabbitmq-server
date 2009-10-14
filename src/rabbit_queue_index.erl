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
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_queue_index).

-export([init/1, terminate/1, terminate_and_erase/1, write_published/4,
         write_delivered/2, write_acks/2, flush_journal/1,
         read_segment_entries/2, next_segment_boundary/1, segment_size/0,
         find_lowest_seq_id_seg_and_next_seq_id/1, start_msg_store/0]).

%%----------------------------------------------------------------------------
%% The queue disk index
%%
%% The queue disk index operates over an ack journal, and a number of
%% segment files. Each segment is the same size, both in max number of
%% entries, and max file size, owing to fixed sized records.
%%
%% Publishes and delivery notes are written directly to the segment
%% files. The segment is found by dividing the sequence id by the the
%% max number of entries per segment. Only the relative sequence
%% within the segment is recorded as the sequence id within a segment
%% file (i.e. sequence id modulo max number of entries per segment).
%% This is keeps entries as small as possible. Publishes and
%% deliveries are only ever going to be received in contiguous
%% ascending order.
%%
%% Acks are written to a bounded journal and are also held in memory,
%% in a dict with the segment file as the key. Again, the records are
%% fixed size: the entire sequence id is written and is limited to a
%% 64-bit unsigned integer. When the journal gets too big, or
%% flush_journal is called, the journal is (possibly incrementally)
%% flushed out to the segment files. As acks can be received from any
%% delivered message in any order, this journal reduces seeking, and
%% batches writes to the segment files, keeping performance high. The
%% flush_journal/1 function returns a boolean indicating whether there
%% is more flushing work that can be done. This means that the process
%% can call this whenever it has an empty mailbox, only a small amount
%% of work is done, allowing the process to respond quickly to new
%% messages if they arrive, or to call flush_journal/1 several times
%% until the result indicates there is no more flushing to be done.
%%
%% On startup, the ack journal is read along with all the segment
%% files, and the ack journal is fully flushed out to the segment
%% files. Care is taken to ensure that no message can be ack'd twice.
%%
%%----------------------------------------------------------------------------

-define(MAX_ACK_JOURNAL_ENTRY_COUNT, 32768).
-define(ACK_JOURNAL_FILENAME, "ack_journal.jif").
-define(SEQ_BYTES, 8).
-define(SEQ_BITS, (?SEQ_BYTES * 8)).
-define(SEGMENT_EXTENSION, ".idx").

-define(REL_SEQ_BITS, 14).
-define(REL_SEQ_BITS_BYTE_ALIGNED, (?REL_SEQ_BITS + (?REL_SEQ_BITS rem 8))).
-define(SEGMENT_ENTRIES_COUNT, 16384). %% trunc(math:pow(2,?REL_SEQ_BITS))).

%% seq only is binary 00 followed by 14 bits of rel seq id
%% (range: 0 - 16383)
-define(REL_SEQ_ONLY_PREFIX, 00).
-define(REL_SEQ_ONLY_PREFIX_BITS, 2).
-define(REL_SEQ_ONLY_ENTRY_LENGTH_BYTES, 2).

%% publish record is binary 1 followed by a bit for is_persistent,
%% then 14 bits of rel seq id, and 128 bits of md5sum msg id
-define(PUBLISH_PREFIX, 1).
-define(PUBLISH_PREFIX_BITS, 1).

-define(MSG_ID_BYTES, 16). %% md5sum is 128 bit or 16 bytes
-define(MSG_ID_BITS, (?MSG_ID_BYTES * 8)).
%% 16 bytes for md5sum + 2 for seq, bits and prefix
-define(PUBLISH_RECORD_LENGTH_BYTES, ?MSG_ID_BYTES + 2).

%% 1 publish, 1 deliver, 1 ack per msg
-define(SEGMENT_TOTAL_SIZE, ?SEGMENT_ENTRIES_COUNT *
        (?PUBLISH_RECORD_LENGTH_BYTES +
         (2 * ?REL_SEQ_ONLY_ENTRY_LENGTH_BYTES))).

%%----------------------------------------------------------------------------

-record(qistate,
        { dir,
          cur_seg_num,
          cur_seg_hdl,
          journal_ack_count,
          journal_ack_dict,
          journal_handle,
          seg_ack_counts
        }).

-include("rabbit.hrl").

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(msg_id() :: binary()).
-type(seq_id() :: integer()).
-type(int_or_undef() :: integer() | 'undefined').
-type(io_dev_or_undef() :: io_device() | 'undefined').
-type(qistate() :: #qistate { dir               :: file_path(),
                              cur_seg_num       :: int_or_undef(),
                              cur_seg_hdl       :: io_dev_or_undef(),
                              journal_ack_count :: integer(),
                              journal_ack_dict  :: dict(),
                              journal_handle    :: io_device(),
                              seg_ack_counts    :: dict()
                            }).

-spec(init/1 :: (queue_name()) -> {non_neg_integer(), qistate()}).
-spec(terminate/1 :: (qistate()) -> qistate()).
-spec(terminate_and_erase/1 :: (qistate()) -> qistate()).
-spec(write_published/4 :: (msg_id(), seq_id(), boolean(), qistate())
      -> qistate()).
-spec(write_delivered/2 :: (seq_id(), qistate()) -> qistate()).
-spec(write_acks/2 :: ([seq_id()], qistate()) -> qistate()).
-spec(flush_journal/1 :: (qistate()) -> {boolean(), qistate()}).
-spec(read_segment_entries/2 :: (seq_id(), qistate()) ->
             {( [{msg_id(), seq_id(), boolean(), boolean()}]
              | 'not_found'), qistate()}).
-spec(next_segment_boundary/1 :: (seq_id()) -> seq_id()).
-spec(segment_size/0 :: () -> non_neg_integer()).
-spec(find_lowest_seq_id_seg_and_next_seq_id/1 :: (qistate()) ->
             {non_neg_integer(), non_neg_integer()}).

-endif.

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

init(Name) ->
    StrName = queue_name_to_dir_name(Name),
    Dir = filename:join(queues_dir(), StrName),
    ok = filelib:ensure_dir(filename:join(Dir, "nothing")),
    {TotalMsgCount, AckCounts, TransientADict} =
        find_ack_counts_and_deliver_transient_msgs(Dir),
    {TotalMsgCount1, AckCounts1} =
        scatter_journal(Dir, TotalMsgCount, AckCounts, TransientADict),
    {ok, JournalHdl} = file:open(filename:join(Dir, ?ACK_JOURNAL_FILENAME),
                                 [raw, binary, delayed_write, write, read]),
    {TotalMsgCount1, #qistate { dir = Dir,
                                cur_seg_num = undefined,
                                cur_seg_hdl = undefined,
                                journal_ack_count = 0,
                                journal_ack_dict = dict:new(),
                                journal_handle = JournalHdl,
                                seg_ack_counts = AckCounts1
                               }}.

terminate(State = #qistate { journal_handle = undefined }) ->
    State;
terminate(State) ->
    case flush_journal(State) of
        {true, State1} ->
            terminate(State1);
        {false, State1 = #qistate { cur_seg_num = SegNum }} ->
            State2 = #qistate { journal_handle = JournalHdl } =
                close_file_handle_for_seg(SegNum, State1),
            ok = file:sync(JournalHdl),
            ok = file:close(JournalHdl),
            State2 #qistate { journal_handle = undefined }
    end.

terminate_and_erase(State) ->
    State1 = terminate(State),
    ok = delete_queue_directory(State1 #qistate.dir),
    State1.

write_published(MsgId, SeqId, IsPersistent, State)
  when is_binary(MsgId) ->
    ?MSG_ID_BYTES = size(MsgId),
    {SegNum, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    {Hdl, State1} = get_file_handle_for_seg(SegNum, State),
    ok = file:write(Hdl,
                    <<?PUBLISH_PREFIX:?PUBLISH_PREFIX_BITS,
                     (bool_to_int(IsPersistent)):1,
                     RelSeq:?REL_SEQ_BITS, MsgId/binary>>),
    State1.

write_delivered(SeqId, State) ->
    {SegNum, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    {Hdl, State1} = get_file_handle_for_seg(SegNum, State),
    ok = file:write(Hdl,
                    <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                     RelSeq:?REL_SEQ_BITS>>),
    State1.

write_acks(SeqIds, State = #qistate { journal_handle    = JournalHdl,
                                      journal_ack_dict  = JAckDict,
                                      journal_ack_count = JAckCount }) ->
    {JAckDict1, JAckCount1} =
        lists:foldl(
          fun (SeqId, {JAckDict2, JAckCount2}) ->
                  ok = file:write(JournalHdl, <<SeqId:?SEQ_BITS>>),
                  {add_ack_to_ack_dict(SeqId, JAckDict2), JAckCount2 + 1}
          end, {JAckDict, JAckCount}, SeqIds),
    State1 = State #qistate { journal_ack_dict = JAckDict1,
                              journal_ack_count = JAckCount1 },
    case JAckCount1 > ?MAX_ACK_JOURNAL_ENTRY_COUNT of
        true -> {_Cont, State2} = flush_journal(State1),
                State2;
        false -> State1
    end.

flush_journal(State = #qistate { journal_ack_count = 0 }) ->
    {false, State};
flush_journal(State = #qistate { journal_handle = JournalHdl,
                                 journal_ack_dict = JAckDict,
                                 journal_ack_count = JAckCount,
                                 seg_ack_counts = AckCounts,
                                 dir = Dir }) ->
    [SegNum|_] = dict:fetch_keys(JAckDict),
    Acks = dict:fetch(SegNum, JAckDict),
    SegPath = seg_num_to_path(Dir, SegNum),
    State1 = close_file_handle_for_seg(SegNum, State),
    AckCounts1 = append_acks_to_segment(SegPath, SegNum, AckCounts, Acks),
    JAckCount1 = JAckCount - length(Acks),
    State2 = State1 #qistate { journal_ack_dict = dict:erase(SegNum, JAckDict),
                               journal_ack_count = JAckCount1,
                               seg_ack_counts = AckCounts1 },
    if
        JAckCount1 == 0 ->
            {ok, 0} = file:position(JournalHdl, 0),
            ok = file:truncate(JournalHdl),
            {false, State2};
        JAckCount1 > ?MAX_ACK_JOURNAL_ENTRY_COUNT ->
            flush_journal(State2);
        true ->
            {true, State2}
    end.

read_segment_entries(InitSeqId, State =
                     #qistate { dir = Dir, journal_ack_dict = JAckDict }) ->
    {SegNum, 0} = seq_id_to_seg_and_rel_seq_id(InitSeqId),
    SegPath = seg_num_to_path(Dir, SegNum),
    {SDict, _AckCount, _HighRelSeq} = load_segment(SegNum, SegPath, JAckDict),
    %% deliberately sort the list desc, because foldl will reverse it
    RelSeqs = rev_sort(dict:fetch_keys(SDict)),
    {lists:foldl(fun (RelSeq, Acc) ->
                         {MsgId, IsDelivered, IsPersistent} =
                             dict:fetch(RelSeq, SDict),
                         [ {MsgId, reconstruct_seq_id(SegNum, RelSeq),
                            IsPersistent, IsDelivered} | Acc]
                 end, [], RelSeqs),
     State}.

next_segment_boundary(SeqId) ->
    {SegNum, _RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    reconstruct_seq_id(SegNum + 1, 0).

segment_size() ->
    ?SEGMENT_ENTRIES_COUNT.

find_lowest_seq_id_seg_and_next_seq_id(
  #qistate { dir = Dir, journal_ack_dict = JAckDict }) ->
    SegNumsPaths = all_segment_nums_paths(Dir),
    %% We don't want the lowest seq_id, merely the seq_id of the start
    %% of the lowest segment. That seq_id may not actually exist, but
    %% that's fine. The important thing is that the segment exists and
    %% the seq_id reported is on a segment boundary.
    LowSeqIdSeg =
        case SegNumsPaths of
            [] -> 0;
            _  -> {SegNum1, _SegPath1} = lists:min(SegNumsPaths),
                  reconstruct_seq_id(SegNum1, 0)
        end,
    NextSeqId =
        case SegNumsPaths of
            [] -> 0;
            _  -> {SegNum2, SegPath2} = lists:max(SegNumsPaths),
                  {_SDict, _AckCount, HighRelSeq} =
                      load_segment(SegNum2, SegPath2, JAckDict),
                  1 + reconstruct_seq_id(SegNum2, HighRelSeq)
        end,
    {LowSeqIdSeg, NextSeqId}.

start_msg_store() ->
    DurableQueues = rabbit_amqqueue:find_durable_queues(),
    DurableQueueNames = 
        sets:from_list([ queue_name_to_dir_name(Queue #amqqueue.name)
                       || Queue <- DurableQueues ]),
    Directories = case file:list_dir(queues_dir()) of
                      {ok, Entries} ->
                          [ Entry || Entry <- Entries, filelib:is_dir(Entry) ];
                      {error, enoent} ->
                          []
                  end,
    {Durable, Transient} =
        lists:foldl(fun (Queue, {DurableAcc, TransientAcc}) ->
                            case sets:is_element(Queue, DurableQueueNames) of
                                true  -> {[Queue | DurableAcc], TransientAcc};
                                false -> {DurableAcc, [Queue | TransientAcc]}
                            end
                    end, {[], []}, Directories),
    MsgStoreDir = filename:join(rabbit_mnesia:dir(), "msg_store"),
    {ok, _Pid} = rabbit_msg_store:start_link(MsgStoreDir,
                                             fun queue_index_walker/1,
                                             Durable),
    lists:foreach(fun (DirName) ->
                          Dir = filename:join(queues_dir(), DirName),
                          ok = delete_queue_directory(Dir)
                  end, Transient),
    {ok, DurableQueues}.

%%----------------------------------------------------------------------------
%% Minor Helpers
%%----------------------------------------------------------------------------

queue_name_to_dir_name(Name = #resource { kind = queue }) ->
    lists:map(fun ($/) -> $_;
                  ($+) -> $-;
                  (C)  -> C
              end, ssl_base64:encode(term_to_binary(Name))).

queues_dir() ->
    filename:join(rabbit_mnesia:dir(), "queues").

rev_sort(List) ->
    lists:sort(fun (A, B) -> B < A end, List).

close_file_handle_for_seg(_SegNum,
                          State = #qistate { cur_seg_num = undefined }) ->
    State;
close_file_handle_for_seg(SegNum, State = #qistate { cur_seg_num = SegNum,
                                                     cur_seg_hdl = Hdl }) ->
    ok = file:sync(Hdl),
    ok = file:close(Hdl),
    State #qistate { cur_seg_num = undefined, cur_seg_hdl = undefined };
close_file_handle_for_seg(_SegNum, State) ->
    State.

get_file_handle_for_seg(SegNum, State = #qistate { cur_seg_num = SegNum,
                                                   cur_seg_hdl = Hdl }) ->
    {Hdl, State};
get_file_handle_for_seg(SegNum, State = #qistate { cur_seg_num = CurSegNum }) ->
    State1 = #qistate { dir = Dir } =
        close_file_handle_for_seg(CurSegNum, State),
    {ok, Hdl} = file:open(seg_num_to_path(Dir, SegNum),
                          [binary, raw, write, delayed_write, read]),
    {ok, _} = file:position(Hdl, {eof, 0}),
    {Hdl, State1 #qistate { cur_seg_num = SegNum, cur_seg_hdl = Hdl}}.

bool_to_int(true ) -> 1;
bool_to_int(false) -> 0.

seq_id_to_seg_and_rel_seq_id(SeqId) ->
    { SeqId div ?SEGMENT_ENTRIES_COUNT, SeqId rem ?SEGMENT_ENTRIES_COUNT }.

reconstruct_seq_id(SegNum, RelSeq) ->
    (SegNum * ?SEGMENT_ENTRIES_COUNT) + RelSeq.

seg_num_to_path(Dir, SegNum) ->
    SegName = integer_to_list(SegNum),
    filename:join(Dir, SegName ++ ?SEGMENT_EXTENSION).    

delete_queue_directory(Dir) ->
    {ok, Entries} = file:list_dir(Dir),
    lists:foreach(fun file:delete/1,
                  [ filename:join(Dir, Entry) || Entry <- Entries ]),
    ok = file:del_dir(Dir).

add_ack_to_ack_dict(SeqId, ADict) ->
    {SegNum, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    dict:update(SegNum, fun(Lst) -> [RelSeq|Lst] end, [RelSeq], ADict).

%%----------------------------------------------------------------------------
%% Msg Store Startup Delta Function
%%----------------------------------------------------------------------------

queue_index_walker([]) ->
    finished;
queue_index_walker([QueueName|QueueNames]) ->
    {TotalMsgCount, State} = init(QueueName),
    {LowSeqIdSeg, _NextSeqId} = find_lowest_seq_id_seg_and_next_seq_id(State),
    queue_index_walker({TotalMsgCount, LowSeqIdSeg, State, QueueNames});

queue_index_walker({0, _LowSeqIdSeg, State, QueueNames}) ->
    terminate(State),
    queue_index_walker(QueueNames);
queue_index_walker({N, LowSeqIdSeg, State, QueueNames}) ->
    {Entries, State1} = read_segment_entries(LowSeqIdSeg, State),
    LowSeqIdSeg1 = LowSeqIdSeg + segment_size(),
    queue_index_walker({Entries, N, LowSeqIdSeg1, State1, QueueNames});

queue_index_walker({[], N, LowSeqIdSeg, State, QueueNames}) ->
    queue_index_walker({N, LowSeqIdSeg, State, QueueNames});
queue_index_walker({[{MsgId, _SeqId, IsPersistent, _IsDelivered} | Entries],
                    N, LowSeqIdSeg, State, QueueNames}) ->
    {MsgId, bool_to_int(IsPersistent),
     {Entries, N - 1, LowSeqIdSeg, State, QueueNames}}.

%%----------------------------------------------------------------------------
%% Startup Functions
%%----------------------------------------------------------------------------

all_segment_nums_paths(Dir) ->
    [{list_to_integer(
        lists:takewhile(fun(C) -> $0 =< C andalso C =< $9 end,
                        SegName)), filename:join(Dir, SegName)}
     || SegName <- filelib:wildcard("*" ++ ?SEGMENT_EXTENSION, Dir)].

find_ack_counts_and_deliver_transient_msgs(Dir) ->
    SegNumsPaths = all_segment_nums_paths(Dir),
    lists:foldl(
      fun ({SegNum, SegPath}, {TotalMsgCount, AckCounts, TransientADict}) ->
              {SDict, AckCount, _HighRelSeq} =
                  load_segment(SegNum, SegPath, dict:new()),
              TransientMsgsAcks = deliver_transient(SegPath, SDict),
              %% ignore TransientMsgsAcks in AckCounts1 and
              %% TotalMsgCount1 because the TransientMsgsAcks fall
              %% through into scatter_journal at which point the
              %% AckCounts and TotalMsgCount will be correctly
              %% adjusted.
              TotalMsgCount1 = TotalMsgCount + dict:size(SDict),
              AckCounts1 = case AckCount of
                               0 -> AckCounts;
                               N -> dict:store(SegNum, N, AckCounts)
                           end,
              TransientADict1 =
                  case TransientMsgsAcks of
                      [] -> TransientADict;
                      _  -> dict:store(SegNum, TransientMsgsAcks, TransientADict)
                  end,
              {TotalMsgCount1, AckCounts1, TransientADict1}
      end, {0, dict:new(), dict:new()}, SegNumsPaths).

scatter_journal(Dir, TotalMsgCount, AckCounts, TransientADict) ->
    JournalPath = filename:join(Dir, ?ACK_JOURNAL_FILENAME),
    case file:open(JournalPath, [read, read_ahead, raw, binary]) of
        {error, enoent} -> {TotalMsgCount, AckCounts};
        {ok, Hdl} ->
            %% ADict may well contain duplicates. However, this is ok,
            %% due to the use of sets in replay_journal_acks_to_segment
            ADict = load_journal(Hdl, TransientADict),
            ok = file:close(Hdl),
            {TotalMsgCount1, AckCounts1, _Dir} =
                dict:fold(fun replay_journal_acks_to_segment/3,
                          {TotalMsgCount, AckCounts, Dir}, ADict),
            ok = file:delete(JournalPath),
            {TotalMsgCount1, AckCounts1}
    end.

load_journal(Hdl, ADict) ->
    case file:read(Hdl, ?SEQ_BYTES) of
        {ok, <<SeqId:?SEQ_BITS>>} ->
            load_journal(Hdl, add_ack_to_ack_dict(SeqId, ADict));
        _ErrOrEoF -> ADict
    end.

replay_journal_acks_to_segment(_, [], Acc) ->
    Acc;
replay_journal_acks_to_segment(SegNum, Acks, {TotalMsgCount, AckCounts, Dir}) ->
    SegPath = seg_num_to_path(Dir, SegNum),
    %% supply empty dict so that we get all msgs in SDict that have
    %% not been acked in the segment file itself
    {SDict, _AckCount, _HighRelSeq} = load_segment(SegNum, SegPath, dict:new()),
    ValidRelSeqIds = dict:fetch_keys(SDict),
    ValidAcks = sets:to_list(sets:intersection(sets:from_list(ValidRelSeqIds),
                                               sets:from_list(Acks))),
    %% ValidAcks will not contain any duplicates at this point.
    {TotalMsgCount - length(ValidAcks),
     append_acks_to_segment(SegPath, SegNum, AckCounts, ValidAcks), Dir}.

deliver_transient(SegPath, SDict) ->
    {AckMe, DeliverMe} =
        dict:fold(
          fun (_RelSeq, {_MsgId, _IsDelivered, true}, Acc) ->
                  Acc;
              (RelSeq, {_MsgId, false, false}, {AckMeAcc, DeliverMeAcc}) ->
                  {[RelSeq | AckMeAcc], [RelSeq | DeliverMeAcc]};
              (RelSeq, {_MsgId, true, false}, {AckMeAcc, DeliverMeAcc}) ->
                  {[RelSeq | AckMeAcc], DeliverMeAcc}
          end, {[], []}, SDict),
    {ok, Hdl} = file:open(SegPath, [binary, raw, write, delayed_write, read]),
    {ok, _} = file:position(Hdl, {eof, 0}),
    ok = file:write(Hdl, [ <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                             RelSeq:?REL_SEQ_BITS>> || RelSeq <- DeliverMe ]),
    ok = file:sync(Hdl),
    ok = file:close(Hdl),
    AckMe.

%%----------------------------------------------------------------------------
%% Loading Segments
%%----------------------------------------------------------------------------

load_segment(SegNum, SegPath, JAckDict) ->
    case file:open(SegPath, [raw, binary, read_ahead, read]) of
        {error, enoent} -> {dict:new(), 0, 0};
        {ok, Hdl} ->
            {SDict, AckCount, HighRelSeq} =
                load_segment_entries(Hdl, dict:new(), 0, 0),
            ok = file:close(Hdl),
            RelSeqs = case dict:find(SegNum, JAckDict) of
                        {ok, RelSeqs1} -> RelSeqs1;
                        error -> []
                      end,
            {SDict1, AckCount1} =
                lists:foldl(fun (RelSeq, {SDict2, AckCount2}) ->
                                    {dict:erase(RelSeq, SDict2), AckCount2 + 1}
                            end, {SDict, AckCount}, RelSeqs),
            {SDict1, AckCount1, HighRelSeq}
    end.

load_segment_entries(Hdl, SDict, AckCount, HighRelSeq) ->
    case file:read(Hdl, 1) of
        {ok, <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
               MSB:(8-?REL_SEQ_ONLY_PREFIX_BITS)>>} ->
            {ok, LSB} = file:read(Hdl, ?REL_SEQ_ONLY_ENTRY_LENGTH_BYTES - 1),
            <<RelSeq:?REL_SEQ_BITS_BYTE_ALIGNED>> = <<MSB, LSB/binary>>,
            {SDict1, AckCount1} = deliver_or_ack_msg(SDict, AckCount, RelSeq),
            load_segment_entries(Hdl, SDict1, AckCount1, HighRelSeq);
        {ok, <<?PUBLISH_PREFIX:?PUBLISH_PREFIX_BITS,
               IsPersistentNum:1, MSB:(7-?PUBLISH_PREFIX_BITS)>>} ->
            %% because we specify /binary, and binaries are complete
            %% bytes, the size spec is in bytes, not bits.
            {ok, <<LSB:1/binary, MsgId:?MSG_ID_BYTES/binary>>} =
                file:read(Hdl, ?PUBLISH_RECORD_LENGTH_BYTES - 1),
            <<RelSeq:?REL_SEQ_BITS_BYTE_ALIGNED>> = <<MSB, LSB/binary>>,
            HighRelSeq1 = lists:max([RelSeq, HighRelSeq]),
            load_segment_entries(
              Hdl, dict:store(RelSeq, {MsgId, false,
                                       1 == IsPersistentNum},
                              SDict), AckCount, HighRelSeq1);
        _ErrOrEoF -> {SDict, AckCount, HighRelSeq}
    end.

deliver_or_ack_msg(SDict, AckCount, RelSeq) ->
    case dict:find(RelSeq, SDict) of
        {ok, {MsgId, false, IsPersistent}} ->
            {dict:store(RelSeq, {MsgId, true, IsPersistent}, SDict), AckCount};
        {ok, {_MsgId, true, _IsPersistent}} ->
            {dict:erase(RelSeq, SDict), AckCount + 1}
    end.


%%----------------------------------------------------------------------------
%% Appending Acks to Segments
%%----------------------------------------------------------------------------

append_acks_to_segment(SegPath, SegNum, AckCounts, Acks) ->
    AckCount = case dict:find(SegNum, AckCounts) of
                   {ok, AckCount1} -> AckCount1;
                   error           -> 0
               end,
    case append_acks_to_segment(SegPath, AckCount, Acks) of
        0 -> AckCounts;
        ?SEGMENT_ENTRIES_COUNT -> dict:erase(SegNum, AckCounts);
        AckCount2 -> dict:store(SegNum, AckCount2, AckCounts)
    end.

append_acks_to_segment(SegPath, AckCount, Acks)
  when length(Acks) + AckCount == ?SEGMENT_ENTRIES_COUNT ->
    ok = case file:delete(SegPath) of
             ok -> ok;
             {error, enoent} -> ok
         end,
    ?SEGMENT_ENTRIES_COUNT;
append_acks_to_segment(SegPath, AckCount, Acks)
  when length(Acks) + AckCount < ?SEGMENT_ENTRIES_COUNT ->
    {ok, Hdl} = file:open(SegPath, [raw, binary, delayed_write, write, read]),
    {ok, _} = file:position(Hdl, {eof, 0}),
    AckCount1 =
        lists:foldl(
          fun (RelSeq, AckCount2) ->
                  ok = file:write(Hdl,
                                  <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                                   RelSeq:?REL_SEQ_BITS>>),
                  AckCount2 + 1
          end, AckCount, Acks),
    ok = file:sync(Hdl),
    ok = file:close(Hdl),
    AckCount1.
