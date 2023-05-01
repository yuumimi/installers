#!/bin/sh

init_arch() {
  ARCH=$(uname -m)
  case $ARCH in
  aarch64 | arm64)
    ARCH="arm64"
    ;;
  amd64 | x64 | x86_64)
    ARCH="amd64"
    ;;
  armv7*)
    ARCH="armv7"
    ;;
  i386 | i686 | i86pc | x86)
    ARCH="386"
    ;;
  s390x)
    ARCH="s390x"
    ;;
  *)
    echo "Architecture ${ARCH} is not supported by this installation script"
    exit 1
    ;;
  esac
}

init_os() {
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  case "$OS" in
  cygwin* | mingw* | msys*)
    OS='windows'
    ;;
  darwin)
    OS='darwin'
    ;;
  linux)
    OS='linux'
    ;;
  *)
    echo "OS ${OS} is not supported by this installation script"
    exit 1
    ;;
  esac
}

# 检查当前用户是否是 root 用户
is_root() {
  if [[ -n "${EUID}" ]] && [[ "${EUID}" -eq 0 ]]; then
    return 0
  elif [[ "$(id -u)" -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

ask_password() {
  # 如果当前用户不是 root 用户，则提示用户输入密码并写入文件
  if ! is_root; then
    if [ ! -s "$HOME/.password" ]; then
      # 进入循环，提示用户输入密码，并将输入的密码写入变量
      while [ -z "${password:-}" ]; do
        echo ""
        unset password
        password=
        echo -n "请输入 '$(id -u -n)' 用户的开机登录密码: " 1>&2
        while IFS= read -r -n1 -s char; do
          # 将用户输入的按键转换为十六进制字符代码
          # 注意，如果是回车或换行符，则返回一个空字符串
          code=${char:+$(printf '%02x' "'$char'")}
          case "$code" in
          '' | 0a | 0d) break ;; # 回车、换行符或者return键，退出循环
          08 | 7f)               # 退格或删除键
            if [ -n "$password" ]; then
              password="$(echo "$password" | sed 's/.$//')"
              echo -n $'\b \b' 1>&2
            fi
            ;;
          1b) ;;           # 忽略ESC键
          5b)              # 忽略方向键
            read -r -n2 -s # 消耗下两个字符（即方向键代码）
            ;;
          [01]?) ;; # 忽略其他所有控制字符
          *)
            password="$password$char"
            echo -n '*' 1>&2
            ;;
          esac
        done
        echo
      done

      # 将密码写入文件
      echo "$password" >"$HOME/.password"
    fi

    # 从文件中读取密码并使用 sudo 命令进行验证
    password=$(cat "$HOME/.password")
    echo "$password" | sudo -S true >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
      return 0
    else
      printf "\n${RED}您输入的密码不正确，请重新启动设备后再次尝试。${RESET}\n\n"
      rm -rf "$HOME/.password"
      exit 1
    fi

  fi
}

process_stop() {
  PROCESS_NAME=$1
  while true; do
    if tasklist | grep -i "${PROCESS_NAME}" >/dev/null 2>&1; then
      taskkill //IM "${PROCESS_NAME}" //F >/dev/null 2>&1
    else
      break
    fi
    sleep 1
  done
}

sudo_cmd() {
  case "$OS" in
  darwin)
    if ! is_root; then
      echo "$password" | sudo -S "${@}"
    else
      "$@"
    fi
    ;;
  linux)
    if ! is_root; then
      echo "$password" | sudo -S "${@}"
    else
      "$@"
    fi
    ;;
  windows)
    "$@"
    ;;
  esac
}

bootstrap_pkg() {

  # get the special formatted version (i.e. "go is go1.14" while node is "node v12.10.8")
  my_versioned_name=""
  _webi_canonical_name() {
    if [ -n "$my_versioned_name" ]; then
      echo "$my_versioned_name"
      return 0
    fi

    if [ -n "$(command -v pkg_format_cmd_version)" ]; then
      my_versioned_name="'$(pkg_format_cmd_version "$PKG_VERSION")'"
    else
      my_versioned_name="'$pkg_cmd_name v$PKG_VERSION'"
    fi

    echo "$my_versioned_name"
  }

  # update symlinks according to $HOME/.local/opt and $HOME/.local/bin install paths.
  # shellcheck disable=2120
  # webi_link may be used in the templated install script
  webi_link() {
    if [ -n "$(command -v pkg_link)" ]; then
      pkg_link
      return 0
    fi

    if [ -n "$WEBI_SINGLE" ] || [ "single" = "${1-}" ]; then
      rm -rf "$pkg_dst_cmd"
      ln -s "$pkg_src_cmd" "$pkg_dst_cmd" 2>/dev/null || cp -f "$pkg_src_cmd" "$pkg_dst_cmd" 2>/dev/null
    else
      # 'pkg_dst' will default to $HOME/.local/opt/<pkg>
      # 'pkg_src' will be the installed version, such as to $HOME/.local/opt/<pkg>-<version>
      rm -rf "$pkg_dst"
      ln -s "$pkg_src" "$pkg_dst" 2>/dev/null || cp -f "$pkg_src" "$pkg_dst" 2>/dev/null
    fi
  }

  # detect if this program is already installed or if an installed version may cause conflict
  webi_check() {
    # Test for existing version
    set +e
    my_path="$PATH"
    PATH="$(dirname "$pkg_dst_cmd"):$PATH"
    export PATH
    my_current_cmd="$(command -v "$pkg_cmd_name")"
    set -e
    if [ -n "$my_current_cmd" ]; then
      my_canonical_name="$(_webi_canonical_name)"
      if [ "$my_current_cmd" != "$pkg_dst_cmd" ]; then
        echo >&2 "WARN: possible PATH conflict between $my_canonical_name and currently installed version"
        echo >&2 "    ${pkg_dst_cmd} (new)"
        echo >&2 "    ${my_current_cmd} (existing)"
        #my_current_version=false
      fi
      # 'readlink' can't read links in paths on macOS 🤦
      # but that's okay, 'cmp -s' is good enough for us
      if cmp -s "${pkg_src_cmd}" "${my_current_cmd}"; then
        echo ""
        echo "${my_canonical_name} already installed:"
        printf "    %s" "${pkg_dst}"
        if [ "${pkg_src_cmd}" != "${my_current_cmd}" ]; then
          printf " => %s" "${pkg_src}"
        fi
        echo ""
        echo ""
        init_singbox
        exit 0
      fi
      if [ -x "$pkg_src_cmd" ]; then
        # shellcheck disable=2119
        # this function takes no args
        webi_link
        echo ""
        echo "switched to $my_canonical_name:"
        echo "    ${pkg_dst} => ${pkg_src}"
        echo ""
        init_singbox
        exit 0
      fi
    fi
    export PATH="$my_path"
  }

  is_interactive_shell() {
    # $- shows shell flags (error,unset,interactive,etc)
    case $- in
    *i*)
      # true
      return 0
      ;;
    *)
      # false
      return 1
      ;;
    esac
  }

  # detect if file is downloaded, and how to download it
  webi_download() {
    # determine the url to download
    if [ -n "${1-}" ]; then
      my_url="$1"
    else
      my_url="$PKG_DOWNLOAD_URL"
    fi

    # determine the location to download to
    if [ -n "${2-}" ]; then
      my_dl="$2"
    else
      my_dl="${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
    fi

    if [ -e "$my_dl" ]; then
      echo "Found $my_dl"
      return 0
    fi

    echo ""
    echo "Downloading $PKG_NAME from $my_url"

    # It's only 2020, we can't expect to have reliable CLI tools
    # to tell us the size of a file as part of a base system...
    if [ -n "$WEBI_WGET" ]; then
      # wget has resumable downloads
      # TODO wget -c --content-disposition "$my_url"
      set +e
      my_show_progress=""
      if is_interactive_shell; then
        my_show_progress="--show-progress"
      fi
      if ! wget -q $my_show_progress --user-agent="wget $UA" -c "$my_url" -O "$my_dl.part"; then
        echo >&2 "failed to download from $PKG_DOWNLOAD_URL"
        exit 1
      fi
      set -e
    else
      # Neither GNU nor BSD curl have sane resume download options, hence we don't bother
      # TODO curl -fsSL --remote-name --remote-header-name --write-out "$my_url"
      my_show_progress="-#"
      if is_interactive_shell; then
        my_show_progress=""
      fi
      # shellcheck disable=SC2086
      # we want the flags to be split
      curl -kfSL $my_show_progress -H "User-Agent: curl $UA" "$my_url" -o "$my_dl.part"
    fi
    mv "$my_dl.part" "$my_dl"
    echo "Saved as $my_dl"
  }

  # detect which archives can be used
  webi_extract() {
    (
      cd "$TMP_DIR"
      if [ "tar.gz" = "$PKG_EXT" ]; then
        echo "Extracting ${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
        tar xf "${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
      elif [ "zip" = "$PKG_EXT" ]; then
        echo "Extracting ${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
        unzip "${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME" >__unzip__.log
      elif [ "exe" = "$PKG_EXT" ]; then
        echo "Moving ${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
        mv "${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME" .
      elif [ "xz" = "$PKG_EXT" ]; then
        echo "Inflating ${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
        unxz -c "${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME" >"$(basename "$PKG_FILE_NAME")"
      else
        # do nothing
        echo "Failed to extract ${PKG_DOWNLOAD_PATH}/$PKG_FILE_NAME"
        exit 1
      fi
    )
  }

  webi_path_add() {
    my_path="$PATH"
    export PATH="$HOME/.local/bin:$PATH"
    export PATH="$my_path"
  }

  # group common pre-install tasks as default
  webi_pre_install() {
    webi_check
    webi_download
    webi_extract
  }

  # move commands from the extracted archive directory to $HOME/.local/opt or $HOME/.local/bin
  # shellcheck disable=2120
  # webi_install may be sourced and used elsewhere
  webi_install() {
    if [ -n "$WEBI_SINGLE" ] || [ "single" = "${1-}" ]; then
      mkdir -p "$(dirname "$pkg_src_cmd")"
      mv ./"$PKG_NAME"-*/"$pkg_cmd_name"* "$pkg_src_cmd"
    else
      rm -rf "$pkg_src"
      mv ./"$PKG_NAME"-*/"$pkg_cmd_name"* "$pkg_src"
    fi
  }

  # run post-install functions - just updating PATH by default
  webi_post_install() {
    webi_path_add "$(dirname "$pkg_dst_cmd")"
  }

  _webi_enable_exec() {
    if [ -n "$(command -v spctl)" ] && [ -n "$(command -v xattr)" ]; then
      # note: some packages contain files that cannot be affected by xattr
      xattr -r -d com.apple.quarantine "$pkg_src" || true
      return 0
    fi
    # TODO need to test that the above actually worked
    # (and proceed to this below if it did not)
    if [ -n "$(command -v spctl)" ]; then
      echo "Checking permission to execute '$pkg_cmd_name' on macOS 11+"
      set +e
      is_allowed="$(spctl -a "$pkg_src_cmd" 2>&1 | grep valid)"
      set -e
      if [ -z "$is_allowed" ]; then
        echo ""
        echo "##########################################"
        echo "#  IMPORTANT: Permission Grant Required  #"
        echo "##########################################"
        echo ""
        echo "Requesting permission to execute '$pkg_cmd_name' on macOS 10.14+"
        echo ""
        sleep 3
        spctl --add "$pkg_src_cmd"
      fi
    fi
  }

  # a friendly message when all is well, showing the final install path in $HOME/.local
  _webi_done_message() {
    echo "Installed $(_webi_canonical_name) as $pkg_dst_cmd"
  }

  ##
  ##
  ## BEGIN custom override functions from <package>/install.sh
  ##
  ##

  WEBI_SINGLE=true

  download() {
    if [ -n "${1-}" ]; then
      my_url="$1"
    fi

    if [ -n "${2-}" ]; then
      my_dl="$2"
    fi

    if [ -n "${3-}" ]; then
      my_name="$3"
    fi

    echo "Downloading $my_name from $my_url"

    if [ -n "$WEBI_WGET" ]; then
      set +e
      my_show_progress=""
      if is_interactive_shell; then
        my_show_progress="--show-progress"
      fi
      if ! wget -q $my_show_progress --user-agent="wget $UA" -c "$my_url" -O "$my_dl.part"; then
        echo >&2 "failed to download"
        exit 1
      fi
      set -e
    else
      my_show_progress="-#"
      if is_interactive_shell; then
        my_show_progress=""
      fi
      curl -kfSL $my_show_progress -H "User-Agent: curl $UA" "$my_url" -o "$my_dl.part"
    fi
    mv "$my_dl.part" "$my_dl"
    if ! [[ "$my_dl" =~ "config.json.tmp" ]]; then
      echo "Saved as $my_dl"
    fi
  }

  singbox_download_deps() {
    pac_txt="${singbox_workdir}/yacd/pac.txt"

    if [ ! -e "${pac_txt}" ] || [ ! -e "${singbox_workdir}/version.txt" ] || [ $(find "${pac_txt}" -mtime +7 -print) ]; then
      echo "0.3.8" >"${singbox_workdir}/version.txt"
      download "$yacd_url" "${PKG_DOWNLOAD_PATH}/yacd.tar.gz" "yacd"
      (cd "$TMP_DIR" && tar xf "${PKG_DOWNLOAD_PATH}/yacd.tar.gz" && cp -f -r "public/" "${singbox_workdir}/yacd/" && echo "Extracting to ${singbox_workdir}/yacd" && echo "")
    fi

    if [ ! -e "${geoip_db}" ] || [ $(find "${geoip_db}" -mtime +7 -print) ]; then
      download "$geoip_url" "$geoip_db" "geoip" && echo ""
    fi

    if [ ! -e "${geosite_db}" ] || [ $(find "${geosite_db}" -mtime +7 -print) ]; then
      download "$geosite_url" "$geosite_db" "geosite" && echo ""
    fi
  }

  singbox_download_config() {
    set +e
    if [ -n "${URL:-}" ]; then
      download "$URL" "${singbox_workdir}/config.json.tmp" "config.json"
    fi
    if [ -f "${singbox_workdir}/config.json.tmp" ]; then
      if "$pkg_dst_cmd" check -c "${singbox_workdir}/config.json.tmp" 2>&1; then
        "$pkg_dst_cmd" format -c "${singbox_workdir}/config.json.tmp" >"${singbox_workdir}/config.json.tmp.tmp"
        mv "${singbox_workdir}/config.json.tmp.tmp" "${singbox_workdir}/config.json.tmp"
        if [ -n "${NIC:-}" ]; then
          sed -i "s/\"auto_detect_interface\": true/\"default_interface\": \"$NIC\"/g" "${singbox_workdir}/config.json.tmp"
        fi
        mv "${singbox_workdir}/config.json.tmp" "${singbox_workdir}/config.json"
        echo -e "Saved as ${singbox_workdir}/config.json"
      else
        rm -rf "${singbox_workdir}/config.json.tmp"
      fi
    fi
    set -e
  }

  singbox_start_message() {
    clear
    echo ""
    echo -e "${GREEN}启动成功,sing-box 正在运行中...${RESET}"
    echo ""
    echo -e "请勿强制关闭本窗口,退出 sing-box 请按 ${BOLD}${ORANGE}CTRL + C${RESET} "
    echo ""
  }

  singbox_stop_message() {
    clear
    echo ""
    echo -e "${RED}退出成功,sing-box 已停止运行.${RESET}"
    echo ""
    echo -e "启动 sing-box 请按 ${BOLD}${ORANGE}上方向键${RESET} 再按 ${BOLD}${ORANGE}回车键${RESET}"
    echo ""
    exit 0
  }

  singbox_start() {
    if [ ! -f "$config_json" ]; then
      echo -e "${RED}配置文件不存在，请重新启动设备后再次尝试。${RESET}" >&2
      exit 1
    fi

    if "$pkg_dst_cmd" check -c "$config_json" 2>&1; then
      :
    else
      echo -e "${RED}配置文件错误，请登陆您的账户并重新复制一键脚本。${RESET}" >&2
      exit 1
    fi

    EXTERNAL_CONTROLLER_PORT=$(awk -F'"' '/external_controller/ {gsub(/[^0-9]/,"",$4); printf("%d\n", $4)}' "$config_json")
    YACD="http://127.0.0.1:$EXTERNAL_CONTROLLER_PORT/ui/#/proxies"

    MIXED_PORT=$(awk '/"type": "mixed"/ {mixed=NR} mixed && /"listen_port"/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$config_json")
    PAC_PORT=$(awk -F':' 'NR==1 {gsub(/;|"|\047/,"",$2);print $2}' "$pac_txt")

    if [ "$PAC_PORT" != "$MIXED_PORT" ]; then
      awk -v mixed_port="$MIXED_PORT" '{gsub(/127\.0\.0\.1:[0-9]+/,"127.0.0.1:" mixed_port)}1' "$pac_txt" >temp && mv temp "$pac_txt"
    fi

    PAC="http://127.0.0.1:$EXTERNAL_CONTROLLER_PORT/ui/pac.txt"

    open_url=$(command -v start || command -v open || command -v xdg-open)

    echo ""
    echo -e "开始启动 sing-box ,请稍等..."

    case "$OS" in
    linux)
      trap singbox_stop_message INT

      sudo_cmd echo "" >"$singbox_log_file"

      (
        for i in {1..8}; do
          if grep -q "sing-box started" "$singbox_log_file"; then
            singbox_start_message
            sleep 3
            $open_url "https://ip.sb" && $open_url "https://youtube.com" && $open_url "$YACD"
            break
          fi
          sleep 1
        done
      ) &

      for i in {1..2}; do
        sudo_cmd "$pkg_dst_cmd" run -D "${singbox_workdir}" && break || sleep 1s
      done

      clear
      echo ""
      echo -e "${RED}启动失败${RESET}"
      echo ""
      echo -e "${BOLD}${ORANGE}请尝试重新启动设备${RESET}"
      echo ""
      exit 1

      ;;
    darwin)
      trap singbox_stop_message INT

      DNS=${DNS:-223.5.5.5}
      sudo_cmd networksetup -setdnsservers Wi-Fi "$DNS"
      sudo_cmd dscacheutil -flushcache
      sudo_cmd killall -HUP mDNSResponder

      sudo_cmd echo "" >"$singbox_log_file"

      (
        for i in {1..8}; do
          if grep -q "sing-box started" "$singbox_log_file"; then
            singbox_start_message
            sleep 3
            $open_url "https://ip.sb" && $open_url "https://youtube.com" && $open_url "$YACD"
            break
          fi
          sleep 1
        done
      ) &

      for i in {1..2}; do
        sudo_cmd "$pkg_dst_cmd" run -D "${singbox_workdir}" && break || sleep 1s
      done

      clear
      echo ""
      echo -e "${RED}启动失败${RESET}"
      echo ""
      echo -e "${BOLD}${ORANGE}请尝试重新启动设备${RESET}"
      echo ""
      exit 1

      ;;
    windows)
      trap singbox_stop_message INT

      echo "" >"$singbox_log_file"

      (
        for i in {1..60}; do
          if grep -q "sing-box started" "$singbox_log_file"; then
            if grep -q "inbound/tun.*started" "$singbox_log_file"; then
              singbox_start_message
              sleep 3
              $open_url "https://ip.sb" && $open_url "https://youtube.com" && $open_url "$YACD"
            else
              clear
              echo ""
              echo -e "${GREEN}启动成功,sing-box 正在运行中...${RESET}"
              echo ""
              echo -e "请勿强制关闭本窗口,退出 sing-box 请按 ${BOLD}${ORANGE}CTRL + C${RESET} "
              echo ""
              echo -e "TUN 虚拟网络接口创建失败,${BOLD}${ORANGE}仅代理 Chrome 和 Edge 流量.${RESET}"
              echo ""
              echo -e "如果要代理其它软件,请将对应软件的代理设置为 SOCKS5://127.0.0.1:2080"
              echo ""
              echo -e "如果要代理本机全部流量,请重新安装操作系统."
              echo ""
            fi
            break
          fi
          sleep 1
        done
      ) &

      for i in {1..2}; do
        "$pkg_dst_cmd" run -D "${singbox_workdir}" && break || sleep 1s
      done

      (
        if reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" >/dev/null 2>&1; then
          process_stop "chrome.exe"
          sleep 3
          start chrome.exe "$YACD" "https://youtube.com" "https://ip.sb" --dns-prefetch-disable --proxy-pac-url="$PAC"
        else
          start "https://www.google.cn/intl/zh-CN/chrome/?standalone=1"
        fi

        if reg query "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe" >/dev/null 2>&1; then
          process_stop "msedge.exe"
          sleep 3
          start msedge.exe "$YACD" "https://youtube.com" "https://ip.sb" --dns-prefetch-disable --proxy-pac-url="$PAC"
        fi
      ) &

      awk -v start=$(awk '/\{/ {count++; if (count==12) {print NR; exit}}' "$config_json") -v end=$(awk '/\}/ {count++; if (count==11) {print NR; exit}}' "$config_json") 'NR<start || NR>end' "$config_json" >"${singbox_workdir}/config_mixed.json"

      for i in {1..2}; do
        "$pkg_dst_cmd" run -D "${singbox_workdir}" -c "${singbox_workdir}/config_mixed.json" && break || sleep 1s
      done

      ;;
    esac

  }

  init_singbox() {
    singbox_download_deps
    singbox_download_config
    singbox_start
  }

  ##
  ##
  ## END custom override functions
  ##
  ##

  # run everything with defaults or overrides as needed
  if command -v pkg_install >/dev/null ||
    command -v pkg_link >/dev/null ||
    command -v pkg_post_install >/dev/null ||
    command -v pkg_done_message >/dev/null ||
    command -v pkg_format_cmd_version >/dev/null ||
    [ -n "${WEBI_SINGLE-}" ] ||
    [ -n "${pkg_cmd_name-}" ] ||
    [ -n "${pkg_dst_cmd-}" ] ||
    [ -n "${pkg_dst_dir-}" ] ||
    [ -n "${pkg_dst-}" ] ||
    [ -n "${pkg_src_cmd-}" ] ||
    [ -n "${pkg_src_dir-}" ] ||
    [ -n "${pkg_src-}" ]; then

    if [ "$OS" = "windows" ]; then
      pkg_cmd_name="${pkg_cmd_name:-$PKG_NAME}.exe"
    else
      pkg_cmd_name="${pkg_cmd_name:-$PKG_NAME}"
    fi

    if [ -n "$WEBI_SINGLE" ]; then
      pkg_dst_cmd="${pkg_dst_cmd:-$HOME/.local/bin/$pkg_cmd_name}"
      pkg_dst="$pkg_dst_cmd" # "$(dirname "$(dirname $pkg_dst_cmd)")"

      pkg_src_cmd="${pkg_src_cmd:-$HOME/.local/opt/$pkg_cmd_name-v$PKG_VERSION/bin/$pkg_cmd_name}"
      pkg_src="$pkg_src_cmd" # "$(dirname "$(dirname $pkg_src_cmd)")"
    else
      pkg_dst="${pkg_dst:-$HOME/.local/opt/$pkg_cmd_name}"
      pkg_dst_cmd="${pkg_dst_cmd:-$pkg_dst/bin/$pkg_cmd_name}"

      pkg_src="${pkg_src:-$HOME/.local/opt/$pkg_cmd_name-v$PKG_VERSION}"
      pkg_src_cmd="${pkg_src_cmd:-$pkg_src/bin/$pkg_cmd_name}"
    fi
    # this script is templated and these are used elsewhere
    # shellcheck disable=SC2034
    pkg_src_bin="$(dirname "$pkg_src_cmd")"
    # shellcheck disable=SC2034
    pkg_dst_bin="$(dirname "$pkg_dst_cmd")"

    if [ -n "$(command -v pkg_pre_install)" ]; then pkg_pre_install; else webi_pre_install; fi

    (
      cd "$TMP_DIR"
      echo "Installing to $pkg_src_cmd"
      if [ -n "$(command -v pkg_install)" ]; then pkg_install; else webi_install; fi
      chmod a+x "$pkg_src"
      chmod a+x "$pkg_src_cmd"
      if [ "$ARCH" = "amd64" ]; then
        if [ -z "$("$pkg_src_cmd" version)" ]; then
          rm -rf "$pkg_src"
          rm -rf "$pkg_src_cmd"
          PKG_FILE_NAME="${PKG_NAME}-${PKG_VERSION}-${OS}-${ARCH}v3.${PKG_EXT}"
          PKG_DOWNLOAD_URL="${PKG_RELEASES}/${PKG_TAG}/${PKG_FILE_NAME}"
          pkg_pre_install
          pkg_install
          chmod a+x "$pkg_src"
          chmod a+x "$pkg_src_cmd"
        fi
      fi
    )

    webi_link

    _webi_enable_exec
    (
      cd "$TMP_DIR"
      if [ -n "$(command -v pkg_post_install)" ]; then pkg_post_install; else webi_post_install; fi
    )

    (
      cd "$TMP_DIR"
      if [ -n "$(command -v pkg_done_message)" ]; then pkg_done_message; else _webi_done_message; fi
    )

    echo ""
  fi

  webi_path_add "$HOME/.local/bin"

  init_singbox

  # cleanup the temp directory
  rm -rf "$TMP_DIR"

  # See? No magic. Just downloading and moving files.

}

# ANSI 转义代码
RED='\033[0;31m'
ORANGE='\033[38;5;208m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
INDIGO='\033[0;35m'
VIOLET='\033[0;36m'
PINK='\033[38;5;219m'
BOLD='\033[1m'
UNDERLINE='\033[4m'
RESET='\033[0m'

# # 打印不同颜色的文本
# echo -e "${RED}红色文本${RESET}"
# echo -e "${ORANGE}橙色文本${RESET}"
# echo -e "${YELLOW}黄色文本${RESET}"
# echo -e "${GREEN}绿色文本${RESET}"
# echo -e "${BLUE}蓝色文本${RESET}"
# echo -e "${INDIGO}靛蓝色文本${RESET}"
# echo -e "${VIOLET}紫罗兰色文本${RESET}"
# echo -e "${PINK}粉色文本${RESET}"
#
# # 打印加粗和下划线文本
# echo -e "${BOLD}加粗文本${RESET}"
# echo -e "${UNDERLINE}下划线文本${RESET}"

args=$(awk 'BEGIN { for(i = 1; i < ARGC; i++) print ARGV[i] }' "$@")

for arg in $args; do
  case $arg in
  https://*)
    URL=$arg
    ;;
  version=*)
    VERSION=${arg#*=}
    ;;
  dns=*)
    DNS=${arg#*=}
    ;;
  nic=*)
    NIC=${arg#*=}
    ;;
  esac
done

init_arch
init_os

case "$OS" in
darwin)
  ask_password
  sudo_cmd pkill sing-box >/dev/null 2>&1
  ;;
linux)
  ask_password
  sudo_cmd pkill sing-box >/dev/null 2>&1
  ;;
windows)
  echo ""
  echo -e "以下软件可能会干扰 sing-box 的正常运行，请退出："
  echo ""
  echo -e "Clash V2ray Shadowsocks 360安全卫士 腾讯电脑管家 联想电脑管家 火绒安全软件"
  process_stop "sing-box.exe"
  ;;
esac

WEBI_PKG="sing-box"
PKG_NAME="sing-box"
PKG_VERSION="${VERSION:-1.2.6}"
PKG_TAG="v${PKG_VERSION}"
PKG_RELEASES="https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download"
# PKG_RELEASES="https://repo.o2cdn.icu/cached-apps/sing-box"
if [ "$OS" = "windows" ]; then
  PKG_EXT=zip
else
  PKG_EXT=tar.gz
fi
PKG_FILE_NAME="${PKG_NAME}-${PKG_VERSION}-${OS}-${ARCH}.${PKG_EXT}"
PKG_DOWNLOAD_URL="${PKG_RELEASES}/${PKG_TAG}/${PKG_FILE_NAME}"
PKG_DOWNLOAD_PATH="${HOME}/.local/tmp/${PKG_NAME}"

# sing-box
singbox_workdir="${HOME}/.local/share/sing-box"
singbox_log_file="${singbox_workdir}/box.log"

config_json_url="${URL:-}"
config_json="${singbox_workdir}/config.json"

yacd_url="https://fastly.jsdelivr.net/gh/caocaocc/archive@sing-dep/yacd.tar.gz"
# yacd_url="https://repo.o2cdn.icu/cached-apps/sing-box/yacd.tar.gz"
yacd_dir="${singbox_workdir}/yacd"

geoip_url="https://fastly.jsdelivr.net/gh/caocaocc/archive@sing-dep/geoip.db"
# geoip_url="https://repo.o2cdn.icu/cached-apps/sing-box/geoip.db"
geoip_db="${singbox_workdir}/geoip.db"

geosite_url="https://fastly.jsdelivr.net/gh/caocaocc/archive@sing-dep/geosite.db"
# geosite_url="https://repo.o2cdn.icu/cached-apps/sing-box/geosite.db"
geosite_db="${singbox_workdir}/geosite.db"

##
## Set up tmp, download, and install directories
##

TMP_DIR=${TMP_DIR:-"$(mktemp -d -t "${WEBI_PKG-}".XXXXXXXX)"}

mkdir -p "${PKG_DOWNLOAD_PATH}"
mkdir -p "${singbox_workdir}"
mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/opt"

##
## Detect http client
##
UA="$(uname -s)/$(uname -r) $(uname -m)/unknown"
set +e
WEBI_CURL="$(command -v curl)"
export WEBI_CURL
WEBI_WGET="$(command -v wget)"
export WEBI_WGET
set -e

bootstrap_pkg
