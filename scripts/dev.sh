# Source this file from the workspace root in Bash or Zsh.
if [ -n "${BASH_VERSION-}" ]; then
    if [ "${BASH_SOURCE}" = "$0" ]; then
        printf '%s\n' 'Run: source scripts/dev.sh' >&2
        exit 1
    fi
elif [ -n "${ZSH_VERSION-}" ]; then
    case "$ZSH_EVAL_CONTEXT" in
        *:file) ;;
        *) printf '%s\n' 'Run: source scripts/dev.sh' >&2; exit 1 ;;
    esac
else
    printf '%s\n' 'Use Bash or Zsh: source scripts/dev.sh' >&2
    return 1 2>/dev/null || exit 1
fi

if [ ! -f scripts/install-local.py ] || [ ! -f typst/typst.toml ]; then
    printf '%s\n' 'Run source scripts/dev.sh from the ZetTypst workspace root.' >&2
    return 1
fi

if ! python3 scripts/install-local.py --link; then
    return 1
fi

export TYPST_PACKAGE_PATH="$PWD/.dev/packages"
printf '%s\n' 'ZetTypst local development environment is ready in this shell.'
