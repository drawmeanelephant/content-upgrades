# shellcheck shell=sh
# Every field is read by scripts/live.sh, which sources this file, and the
# quotes in KNAP_ACP_AGENT are for knap-mcp's own argv splitter, not the shell.
# shellcheck disable=SC2034,SC2089,SC2090
# Provider profiles for scripts/live.sh. Sourced, not run.
#
# A profile is one case arm in knap_profile. It sets:
#
#   backend   the knap-mcp backend kind
#   label     the provenance label for tables: the model, and what it went
#             through (direct API, ACP agent, proxy)
#   needs     env vars that must be non-empty, space-separated
#   cmds      commands that must be on PATH
#   expect    a glob the resolved model must match. Agents fall back to a
#             default model without saying so, so a mismatch stops the run
#   scratch   1: results go to a temp dir unless --out is given
#
# and exports whatever KNAP_* settings the backend reads. Keys come from the
# caller's environment, never from this file.
#
# Adding a provider is one case arm plus its name in KNAP_PROFILES. Private
# profiles (a local proxy, an extra account) go in $KNAP_PROVIDERS_LOCAL
# (default ~/.config/knap/providers.sh) as a knap_profile_local function
# with the same contract plus a KNAP_PROFILES_LOCAL list; they're tried first.

KNAP_PROFILES="fake spark wonder baseten compat ollama opencode-spark-1.3 opencode-spark-1.2 opencode-wonder-1.0 devin-wonder devin-swe-2 devin-summarizer"

# opencode acp has no --model flag and defaults to opencode/flint-40b-free,
# so the model always goes through OPENCODE_CONFIG_CONTENT. The single quotes
# matter: knap-mcp's argv splitter groups on " too, so an unquoted
# {"model":...} arrives as {model:...}, which opencode ignores silently.
knap_opencode() {
    backend=acp cmds=opencode expect="opencode/$1"
    label="$2 via ACP (opencode)"
    export KNAP_ACP_AGENT="env 'OPENCODE_CONFIG_CONTENT={\"model\":\"opencode/$1\"}' opencode acp"
}

knap_profile() {
    case $1 in
    fake)
        backend=acp expect=fake-model-1 scratch=1
        label='fake ACP agent (harness self-test, no model)'
        export KNAP_ACP_AGENT="/bin/sh '$KNAP_ROOT/knap-mcp/src/acp_fake_agent.sh' echo"
        ;;
    spark) backend=spark needs=MODEL_API_KEY label='Muse Spark (direct Meta API)' ;;
    wonder) backend=wonder needs=MODEL_API_KEY label='Muse Wonder (direct Meta API)' ;;
    baseten) backend=baseten needs=MODEL_API_KEY label='Muse Spark open (Baseten)' ;;
    compat)
        backend=compat needs='KNAP_COMPAT_URL KNAP_COMPAT_MODEL'
        label=${KNAP_COMPAT_LABEL:-"${KNAP_COMPAT_MODEL:-?} via OpenAI-compatible endpoint (set KNAP_COMPAT_LABEL)"}
        ;;
    ollama)
        backend=compat needs=OLLAMA_MODEL cmds=ollama
        label="${OLLAMA_MODEL:-?} via ollama (local)"
        export KNAP_COMPAT_URL="${OLLAMA_URL:-http://127.0.0.1:11434/v1/chat/completions}"
        export KNAP_COMPAT_MODEL="${OLLAMA_MODEL:-}"
        unset KNAP_COMPAT_KEY
        ;;
    opencode-spark-1.3) knap_opencode muse-spark-1.3 'Muse Spark 1.3' ;;
    opencode-spark-1.2) knap_opencode muse-spark-1.2 'Muse Spark 1.2' ;;
    opencode-wonder-1.0) knap_opencode muse-wonder-1.0 'Muse Wonder 1.0' ;;
    devin-wonder)
        backend=acp cmds=devin expect='muse-wonder-1-0-*'
        label='Muse Wonder 1.0 via ACP (devin, low thinking)'
        export KNAP_ACP_AGENT='devin acp --model muse-wonder-1-0-low'
        ;;
    devin-swe-2)
        backend=acp cmds=devin expect='swe-2-*'
        label='SWE-2 via ACP (devin, free tier)'
        export KNAP_ACP_AGENT='devin acp --model swe-2-medium'
        ;;
    devin-summarizer)
        backend=acp cmds=devin expect='*'
        label='devin summarizer agent via ACP'
        export KNAP_ACP_AGENT='devin acp --agent-type summarizer'
        ;;
    *) return 1 ;;
    esac
}
