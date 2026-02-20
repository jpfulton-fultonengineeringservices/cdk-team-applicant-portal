# portal-deps.sh
#
# Dependency detection and auto-install for ApplicantPortal management scripts.
# Source this file; do not execute it directly.
#
# Provides a single public function:
#   ensure_dependencies   Probes for required tools, detects platform and
#                         package manager, and offers to install anything
#                         that is missing.
#
# Reads globals: YES (from caller)

# ---------------------------------------------------------------------------
# _detect_os
#
# Prints "macos" or "linux". Exits with an error on unsupported platforms.
# ---------------------------------------------------------------------------
_detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)
      echo "WARNING: Unsupported OS '$(uname -s)'. Auto-install is not available." >&2
      echo "unknown"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _detect_package_manager
#
# Probes for common package managers and prints the first one found.
# Returns empty string if none is detected.
# ---------------------------------------------------------------------------
_detect_package_manager() {
  local mgr
  for mgr in brew apt-get dnf yum apk pacman; do
    if command -v "${mgr}" &>/dev/null; then
      echo "${mgr}"
      return 0
    fi
  done
  echo ""
}

# ---------------------------------------------------------------------------
# _ensure_homebrew
#
# macOS only. Checks for brew; if absent, offers to install it via the
# official installer. After install, evals brew shellenv so the current
# shell can use it immediately.
#
# Reads globals: YES
# ---------------------------------------------------------------------------
_ensure_homebrew() {
  if command -v brew &>/dev/null; then
    return 0
  fi

  local os
  os="$(_detect_os)"
  if [[ "${os}" != "macos" ]]; then
    return 1
  fi

  echo "" >&2
  echo "Homebrew is not installed. It is the recommended package manager for macOS" >&2
  echo "and is needed to install missing dependencies (aws, jq)." >&2
  echo "" >&2
  echo "  Install command:" >&2
  echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
  echo "" >&2

  local do_install=false
  if [[ "${YES:-false}" == "true" ]]; then
    do_install=true
  elif [[ -t 0 ]]; then
    local _ans
    read -r -p "Install Homebrew now? [y/N] " _ans
    if [[ "${_ans}" =~ ^[Yy]$ ]]; then
      do_install=true
    fi
  fi

  if [[ "${do_install}" == false ]]; then
    echo "Skipping Homebrew installation." >&2
    return 1
  fi

  echo "Installing Homebrew..." >&2
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Make brew available in the current shell (Apple Silicon vs Intel paths)
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if ! command -v brew &>/dev/null; then
    echo "WARNING: Homebrew install completed but 'brew' is not on PATH." >&2
    return 1
  fi

  echo "Homebrew installed successfully." >&2
  return 0
}

# ---------------------------------------------------------------------------
# _ensure_nvm
#
# Checks for nvm (a shell function, not a binary). Sources it from common
# locations if found but not loaded. Installs it via the official installer
# if absent entirely.
#
# After this function returns 0, the `nvm` function is available in the
# current shell.
#
# Reads globals: YES
# ---------------------------------------------------------------------------
_ensure_nvm() {
  # nvm is a shell function — check with `type`
  if type nvm &>/dev/null; then
    return 0
  fi

  # Try sourcing from known locations
  local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
  if [[ -s "${nvm_dir}/nvm.sh" ]]; then
    export NVM_DIR="${nvm_dir}"
    source "${nvm_dir}/nvm.sh"
    if type nvm &>/dev/null; then
      return 0
    fi
  fi

  echo "" >&2
  echo "nvm (Node Version Manager) is not installed. It is the recommended way" >&2
  echo "to install Node.js for these scripts." >&2
  echo "" >&2
  echo "  Install command:" >&2
  echo '    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash' >&2
  echo "" >&2

  local do_install=false
  if [[ "${YES:-false}" == "true" ]]; then
    do_install=true
  elif [[ -t 0 ]]; then
    local _ans
    read -r -p "Install nvm now? [y/N] " _ans
    if [[ "${_ans}" =~ ^[Yy]$ ]]; then
      do_install=true
    fi
  fi

  if [[ "${do_install}" == false ]]; then
    echo "Skipping nvm installation." >&2
    return 1
  fi

  echo "Installing nvm..." >&2
  export NVM_DIR="${nvm_dir}"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

  # Source nvm into the current shell
  if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    source "${NVM_DIR}/nvm.sh"
  fi

  if ! type nvm &>/dev/null; then
    echo "WARNING: nvm install completed but the nvm function is not available." >&2
    return 1
  fi

  echo "nvm installed successfully." >&2
  return 0
}

# ---------------------------------------------------------------------------
# _install_node_via_nvm
#
# Ensures nvm is available, then installs the latest Node.js LTS release.
# Verifies `node` is on PATH afterward.
# ---------------------------------------------------------------------------
_install_node_via_nvm() {
  if ! _ensure_nvm; then
    return 1
  fi

  echo "Installing Node.js (latest LTS) via nvm..." >&2
  nvm install --lts

  if ! command -v node &>/dev/null; then
    echo "WARNING: nvm install --lts completed but 'node' is not on PATH." >&2
    return 1
  fi

  echo "Node.js $(node --version) installed successfully." >&2
  return 0
}

# ---------------------------------------------------------------------------
# _pkg_name <tool> <package-manager>
#
# Maps a tool name to the correct package name for the given package manager.
# Prints the package name, or empty string if the tool does not need a
# package on this platform (e.g. column is built-in on macOS).
# ---------------------------------------------------------------------------
_pkg_name() {
  local tool="$1"
  local mgr="$2"

  case "${tool}" in
    aws)
      case "${mgr}" in
        brew)    echo "awscli"     ;;
        apk)     echo "aws-cli"    ;;
        pacman)  echo "aws-cli-v2" ;;
        *)       echo "awscli"     ;;
      esac
      ;;
    jq)
      echo "jq"
      ;;
    column)
      case "${mgr}" in
        brew)    echo "" ;;  # built-in on macOS
        apt-get) echo "bsdmainutils" ;;
        *)       echo "util-linux"   ;;
      esac
      ;;
    *)
      echo ""
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _build_install_cmd <package-manager> <packages...>
#
# Composes a ready-to-run install command string for the given package
# manager and list of packages.
# ---------------------------------------------------------------------------
_build_install_cmd() {
  local mgr="$1"
  shift
  local pkgs="$*"

  if [[ -z "${pkgs}" ]]; then
    echo ""
    return
  fi

  case "${mgr}" in
    brew)    echo "brew install ${pkgs}" ;;
    apt-get) echo "sudo apt-get update && sudo apt-get install -y ${pkgs}" ;;
    dnf)     echo "sudo dnf install -y ${pkgs}" ;;
    yum)     echo "sudo yum install -y ${pkgs}" ;;
    apk)     echo "sudo apk add ${pkgs}" ;;
    pacman)  echo "sudo pacman -S --noconfirm ${pkgs}" ;;
    *)       echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# ensure_dependencies
#
# Single entry point for upfront dependency verification and auto-install.
# Probes for all required/recommended tools, classifies what is missing,
# detects the platform and package manager, and offers to install
# everything in one pass.
#
# Reads globals: YES
# ---------------------------------------------------------------------------
ensure_dependencies() {
  # --- 1. Probe ---
  local has_aws=false has_jq=false has_node=false has_column=false
  command -v aws    &>/dev/null && has_aws=true
  command -v jq     &>/dev/null && has_jq=true
  command -v node   &>/dev/null && has_node=true
  command -v column &>/dev/null && has_column=true

  # If node is not on PATH, try sourcing nvm first (it may be installed
  # but not loaded in this shell session).
  if [[ "${has_node}" == false ]]; then
    local nvm_dir="${NVM_DIR:-${HOME}/.nvm}"
    if [[ -s "${nvm_dir}/nvm.sh" ]]; then
      export NVM_DIR="${nvm_dir}"
      source "${nvm_dir}/nvm.sh"
      if command -v node &>/dev/null; then
        has_node=true
      fi
    fi
  fi

  # --- 2–6. Classify ---
  local missing_required=()
  local missing_recommended=()

  if [[ "${has_aws}" == false ]]; then
    missing_required+=("aws")
  fi

  if [[ "${has_jq}" == false && "${has_node}" == false ]]; then
    missing_required+=("jq")
  fi

  if [[ "${has_node}" == true && "${has_jq}" == false ]]; then
    missing_recommended+=("jq")
  fi

  if [[ "${has_column}" == false ]]; then
    missing_recommended+=("column")
  fi

  # --- 7. Nothing missing → silent return ---
  if [[ ${#missing_required[@]} -eq 0 && ${#missing_recommended[@]} -eq 0 ]]; then
    return 0
  fi

  # --- 8. Print diagnostic ---
  echo "" >&2
  echo "Dependency check:" >&2
  echo "  aws ........... $(${has_aws}    && echo "ok" || echo "MISSING")" >&2
  echo "  jq ............ $(${has_jq}     && echo "ok" || echo "missing")" >&2
  echo "  node .......... $(${has_node}   && echo "ok" || echo "missing")" >&2
  echo "  column ........ $(${has_column} && echo "ok" || echo "missing")" >&2
  echo "" >&2

  if [[ ${#missing_required[@]} -gt 0 ]]; then
    echo "Required (scripts will not work without these):" >&2
    for t in "${missing_required[@]}"; do
      echo "  - ${t}" >&2
    done
  fi
  if [[ ${#missing_recommended[@]} -gt 0 ]]; then
    echo "Recommended (scripts work without these but with reduced functionality):" >&2
    for t in "${missing_recommended[@]}"; do
      case "${t}" in
        jq)     echo "  - jq      (node works but jq is faster and lighter)" >&2 ;;
        column) echo "  - column  (needed for table output format in list-users.sh)" >&2 ;;
        *)      echo "  - ${t}" >&2 ;;
      esac
    done
  fi

  # --- 9. Detect OS + package manager ---
  local os pkg_mgr
  os="$(_detect_os)"
  pkg_mgr="$(_detect_package_manager)"

  # --- 10. macOS without brew → offer Homebrew install ---
  if [[ "${os}" == "macos" && -z "${pkg_mgr}" ]]; then
    if _ensure_homebrew; then
      pkg_mgr="$(_detect_package_manager)"
    fi
  fi

  # --- 11. Compute install actions ---

  # Determine which tools the package manager should install
  local pkg_tools=()     # tools to install via package manager
  local need_node=false  # whether to install node via nvm

  local all_missing=("${missing_required[@]}" "${missing_recommended[@]}")

  for t in "${all_missing[@]}"; do
    case "${t}" in
      node)
        need_node=true
        ;;
      *)
        pkg_tools+=("${t}")
        ;;
    esac
  done

  # If jq is in the missing list and node is also missing, the user will
  # get jq via the package manager. But if we later cannot install jq,
  # we'll fall back to offering node via nvm.

  # Resolve package names
  local pkg_names=()
  if [[ -n "${pkg_mgr}" ]]; then
    for t in "${pkg_tools[@]}"; do
      local pname
      pname="$(_pkg_name "${t}" "${pkg_mgr}")"
      if [[ -n "${pname}" ]]; then
        pkg_names+=("${pname}")
      fi
    done
  fi

  # Build the install command
  local install_cmd=""
  if [[ ${#pkg_names[@]} -gt 0 && -n "${pkg_mgr}" ]]; then
    install_cmd="$(_build_install_cmd "${pkg_mgr}" "${pkg_names[*]}")"
  fi

  # Display what will be done
  echo "" >&2
  if [[ -n "${install_cmd}" ]]; then
    echo "Package manager install command:" >&2
    echo "  ${install_cmd}" >&2
  fi
  if [[ "${need_node}" == true ]] || { [[ "${has_jq}" == false && "${has_node}" == false ]] && [[ -z "${install_cmd}" ]]; }; then
    echo "Node.js will be installed via nvm (latest LTS)." >&2
    need_node=true
  fi
  if [[ -z "${install_cmd}" && "${need_node}" == false ]]; then
    if [[ -z "${pkg_mgr}" ]]; then
      echo "No supported package manager detected. Please install the missing tools manually." >&2
      if [[ ${#missing_required[@]} -gt 0 ]]; then
        exit 1
      fi
      return 0
    fi
  fi

  # --- 12. Offer install ---
  local do_install="none"

  if [[ ${#missing_required[@]} -eq 0 ]]; then
    # Only recommended tools are missing — less urgent prompt
    if [[ "${YES:-false}" == "true" ]]; then
      do_install="all"
    elif [[ -t 0 ]]; then
      echo "" >&2
      local _ans
      read -r -p "Install recommended tools? [y/N] " _ans
      if [[ "${_ans}" =~ ^[Yy]$ ]]; then
        do_install="all"
      else
        do_install="skip"
      fi
    else
      do_install="skip"
    fi
  else
    # Required tools are missing — three-way prompt
    if [[ "${YES:-false}" == "true" ]]; then
      do_install="all"
    elif [[ -t 0 ]]; then
      echo "" >&2
      echo "  [I]nstall all    — install required + recommended tools" >&2
      echo "  [r]equired only  — install only what is strictly needed" >&2
      echo "  [s]kip           — do not install anything (script will exit if required tools are missing)" >&2
      echo "" >&2
      local _ans
      read -r -p "Choice [I/r/s]: " _ans
      case "${_ans}" in
        [Rr]*)  do_install="required" ;;
        [Ss]*)  do_install="skip"     ;;
        *)      do_install="all"      ;;
      esac
    else
      echo "" >&2
      echo "Non-interactive environment. Install the missing tools manually and re-run." >&2
      if [[ ${#missing_required[@]} -gt 0 ]]; then
        exit 1
      fi
      return 0
    fi
  fi

  # --- 13. Execute installs ---
  if [[ "${do_install}" == "skip" ]]; then
    if [[ ${#missing_required[@]} -gt 0 ]]; then
      echo "" >&2
      echo "ERROR: Required tools are missing. Cannot continue." >&2
      exit 1
    fi
    echo "" >&2
    echo "Continuing without recommended tools." >&2
    return 0
  fi

  # Determine what to actually install based on the choice
  local install_pkg=false
  local install_nvm_node=false

  if [[ "${do_install}" == "all" ]]; then
    [[ -n "${install_cmd}" ]] && install_pkg=true
    [[ "${need_node}" == true ]] && install_nvm_node=true
  elif [[ "${do_install}" == "required" ]]; then
    # Only install packages for required tools
    local req_pkg_names=()
    if [[ -n "${pkg_mgr}" ]]; then
      for t in "${missing_required[@]}"; do
        case "${t}" in
          node) install_nvm_node=true ;;
          *)
            local pname
            pname="$(_pkg_name "${t}" "${pkg_mgr}")"
            if [[ -n "${pname}" ]]; then
              req_pkg_names+=("${pname}")
            fi
            ;;
        esac
      done
    fi
    if [[ ${#req_pkg_names[@]} -gt 0 ]]; then
      install_cmd="$(_build_install_cmd "${pkg_mgr}" "${req_pkg_names[*]}")"
      install_pkg=true
    fi
  fi

  echo "" >&2

  if [[ "${install_pkg}" == true && -n "${install_cmd}" ]]; then
    echo "Running: ${install_cmd}" >&2
    eval "${install_cmd}"
    echo "" >&2

    # Note about AWS CLI v1 vs v2 on non-brew Linux managers
    if [[ "${os}" == "linux" && "${pkg_mgr}" != "brew" ]]; then
      if command -v aws &>/dev/null; then
        local aws_ver
        aws_ver="$(aws --version 2>/dev/null || true)"
        if [[ "${aws_ver}" == aws-cli/1.* ]]; then
          echo "NOTE: Your system installed AWS CLI v1. For full feature support," >&2
          echo "      consider upgrading to AWS CLI v2:" >&2
          echo "      https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
          echo "" >&2
        fi
      fi
    fi
  fi

  if [[ "${install_nvm_node}" == true ]]; then
    _install_node_via_nvm || true
    echo "" >&2
  fi

  # --- 14. Re-verify ---
  local still_missing=()

  if ! command -v aws &>/dev/null; then
    still_missing+=("aws")
  fi
  if ! command -v jq &>/dev/null && ! command -v node &>/dev/null; then
    still_missing+=("jq or node")
  fi

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    echo "ERROR: The following required tools are still missing after install:" >&2
    for t in "${still_missing[@]}"; do
      echo "  - ${t}" >&2
    done
    echo "" >&2
    echo "Install them manually and re-run the script." >&2
    exit 1
  fi

  # Non-fatal warnings for recommended tools
  if ! command -v jq &>/dev/null; then
    echo "NOTE: jq is not installed. Scripts will use node for JSON parsing." >&2
    echo "      For better performance, install jq: https://jqlang.github.io/jq/" >&2
  fi
  if ! command -v column &>/dev/null; then
    echo "NOTE: column is not installed. The 'table' output format in list-users.sh" >&2
    echo "      may not align correctly." >&2
  fi

  echo "" >&2
  return 0
}
