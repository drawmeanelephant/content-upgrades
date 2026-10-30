#!/bin/sh
# A fake ACP agent for acp.zig's tests: newline-delimited JSON-RPC on
# stdin/stdout, answering only the request shapes knap-mcp's client sends
# (`{"jsonrpc":"2.0","id":N,"method":...}`). $1 picks the behaviour of
# session/prompt:
#
#   ok      noise, a thought, another session's chunk, a permission
#           request, then "reply from s<N>" in three chunks
#   fenced  a fenced repair patch
#   maxtok  a cut-off reply (stopReason max_tokens)
#   hang    no reply until session/cancel arrives
#   mute    no reply at all, even to session/cancel
#   deaf    replies like ok, but ignores stdin EOF: once knap-mcp closes
#           the pipe the script sleeps on instead of exiting
#   stuffed answers session/new, then stops reading stdin entirely so a
#           large session/prompt write backs up in the pipe
#   crash   exit mid-turn
#   auth    session/new fails with an auth error
#   v2      initialize answers protocolVersion 2
#   cap1    session/new fails once one session is already open — droid's
#           ~49-session cap scaled down to 1; session/close frees the slot
#   flake   the first session/new of the first process fails with a bare
#           "Internal error" (droid's cap reply); a respawned process
#           finds the state file and answers
#   echo    replies with the prompt's last `knap-smoke-<task>` token, or
#           with a closed `{% if %}` region when there is none
#
# session/new reports model `fake-model-1` and effort `low` in
# configOptions (mode `legacy`: only the older models.currentModelId).
mode=$1
sessions=0
open=0
pending=
while IFS= read -r line; do
  id=$(printf '%s\n' "$line" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
  case $line in
  *'"method":"initialize"'*)
    v=1
    [ "$mode" = v2 ] && v=2
    printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":%s,"agentCapabilities":{},"authMethods":[]}}\n' "$id" "$v"
    ;;
  *'"method":"session/new"'*)
    if [ "$mode" = auth ]; then
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32000,"message":"Authentication required"}}\n' "$id"
      continue
    fi
    if [ "$mode" = cap1 ] && [ "$open" -ge 1 ]; then
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"Internal error"}}\n' "$id"
      continue
    fi
    if [ "$mode" = flake ] && [ ! -f "$(dirname "$0")/flake.seen" ]; then
      : >"$(dirname "$0")/flake.seen"
      printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":"Internal error"}}\n' "$id"
      continue
    fi
    sessions=$((sessions + 1))
    open=$((open + 1))
    printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s%s","update":{"sessionUpdate":"available_commands_update","availableCommands":[]}}}\n' "$sessions"
    if [ "$mode" = legacy ]; then
      printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s%s","models":{"currentModelId":"fake-legacy","availableModels":[]}}}\n' "$id" "$sessions"
      continue
    fi
    printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s%s","configOptions":[{"id":"mode","category":"mode","type":"select","currentValue":"ask","options":[]},{"id":"model","name":"Model","category":"model","type":"select","currentValue":"fake-model-1","options":[]},{"id":"effort","category":"thought_level","type":"select","currentValue":"low","options":[]}]}}\n' "$id" "$sessions"
    # stuffed: the session exists, but stdin is never read again — the
    # next write past the pipe buffer blocks until the client's deadline.
    [ "$mode" = stuffed ] && exec sleep 3600
    ;;
  *'"method":"session/prompt"'*)
    s="s$sessions"
    case $mode in
    ok | deaf | cap1 | flake)
      printf '{"jsonrpc":"2.0","method":"_vendor/noise","params":{}}\n'
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"thinking"}}}}\n' "$s"
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"other","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"WRONG"}}}}\n'
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"reply "}}}}\n' "$s"
      printf '{"jsonrpc":"2.0","id":900,"method":"session/request_permission","params":{"sessionId":"%s","toolCall":{"toolCallId":"t1"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"}]}}\n' "$s"
      IFS= read -r answer
      case $answer in
      *'"id":900,"result":{"outcome":{"outcome":"cancelled"}}'*) ;;
      *) printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"PERMISSION GRANTED "}}}}\n' "$s" ;;
      esac
      printf '{"jsonrpc":"2.0","id":901,"method":"fs/read_text_file","params":{"sessionId":"%s","path":"/etc/hosts"}}\n' "$s"
      IFS= read -r answer
      case $answer in
      *'"id":901,"error":'*) ;;
      *) printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"FILE READ "}}}}\n' "$s" ;;
      esac
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"from "}}}}\n' "$s"
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"%s"}}}}\n' "$s" "$s"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn","usage":{"inputTokens":40,"outputTokens":3,"totalTokens":43,"thoughtTokens":1}}}\n' "$id"
      ;;
    fenced)
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"```knap\\n{%% if a %%}A{%% endif %%}\\n```"}}}}\n' "$s"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
      ;;
    maxtok)
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"{%% if a"}}}}\n' "$s"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"max_tokens"}}\n' "$id"
      ;;
    echo)
      tok=$(printf '%s\n' "$line" | sed -n 's/.*\(knap-smoke-[a-z]*\).*/\1/p')
      text=${tok:-'{%% if items %%}\\n- {{ items | first }}\\n{%% endif %%}\\n'}
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"'"$text"'"}}}}\n' "$s"
      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn","usage":{"inputTokens":20,"outputTokens":2,"totalTokens":22}}}\n' "$id"
      ;;
    hang | mute) pending=$id ;;
    crash) exit 3 ;;
    esac
    ;;
  *'"method":"session/close"'*)
    open=$((open - 1)); [ "$open" -lt 0 ] && open=0
    printf '{"jsonrpc":"2.0","id":%s,"result":{}}\n' "$id"
    ;;
  *'"method":"session/cancel"'*)
    [ "$mode" = hang ] && printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"cancelled"}}\n' "$pending"
    ;;
  esac
done
# deaf: stdin hit EOF and the loop ended, but an agent that ignores EOF
# keeps running — knap-mcp must kill it, not trust it to exit.
[ "$mode" = deaf ] && exec sleep 3600
