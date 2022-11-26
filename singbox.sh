#!/bin/sh

__bootstrap_webi() {

	set -e
	set -u

	WEBI_HOST='https://ghproxy.com'
	WEBI_RELEASES='https://github.com/SagerNet/sing-box/releases/download'
	WEBI_PKG='sing-box'
	PKG_NAME='sing-box'
	WEBI_OS="${OS}"
	WEBI_ARCH="${ARCH}"
	WEBI_VERSION="${VERSION:-1.1-beta18}"
	WEBI_TAG="v${WEBI_VERSION}"
	if [ "$OS" = "windows" ]; then
		WEBI_EXT='zip'
	else
		WEBI_EXT='tar.gz'
	fi
	WEBI_PKG_FILE="${PKG_NAME}-${WEBI_VERSION}-${WEBI_OS}-${WEBI_ARCH}.${WEBI_EXT}"
	WEBI_PKG_URL="${WEBI_HOST}/${WEBI_RELEASES}/${WEBI_TAG}/${WEBI_PKG_FILE}"
	WEBI_UA="$(uname -a)"
	WEBI_PKG_DOWNLOAD=""
	WEBI_PKG_WORKDIR="${HOME}/.local/share/${PKG_NAME}"
	WEBI_PKG_PATH="${HOME}/.local/tmp/${PKG_NAME}"

	##
	## Set up tmp, download, and install directories
	##

	WEBI_TMP=${WEBI_TMP:-"$(mktemp -d -t webinstall-"${WEBI_PKG:-}".XXXXXXXX)"}
	export _webi_tmp="${_webi_tmp:-"$HOME/.local/opt/webi-tmp.d"}"

	mkdir -p "${WEBI_PKG_WORKDIR}"
	mkdir -p "${WEBI_PKG_PATH}"
	mkdir -p "$HOME/.local/bin"
	mkdir -p "$HOME/.local/opt"

	##
	## Detect http client
	##
	set +e
	WEBI_CURL="$(command -v curl)"
	export WEBI_CURL
	WEBI_WGET="$(command -v wget)"
	export WEBI_WGET
	set -e

	# get the special formatted version (i.e. "go is go1.14" while node is "node v12.10.8")
	my_versioned_name=""
	_webi_canonical_name() {
		if [ -n "$my_versioned_name" ]; then
			echo "$my_versioned_name"
			return 0
		fi

		if [ -n "$(command -v pkg_format_cmd_version)" ]; then
			my_versioned_name="'$(pkg_format_cmd_version "$WEBI_VERSION")'"
		else
			my_versioned_name="'$pkg_cmd_name v$WEBI_VERSION'"
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

		if [ -n "$WEBI_SINGLE" ] || [ "single" = "${1:-}" ]; then
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
		my_current_cmd="$(command -v "$pkg_cmd_name$pkg_ext_name")"
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
		if [ -n "${1:-}" ]; then
			my_url="$1"
		else
			my_url="$WEBI_PKG_URL"
		fi

		# determine the location to download to
		if [ -n "${2:-}" ]; then
			my_dl="$2"
		else
			my_dl="${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
		fi

		WEBI_PKG_DOWNLOAD="${my_dl}"
		export WEBI_PKG_DOWNLOAD

		if [ -e "$my_dl" ]; then
			echo "Found $my_dl"
			return 0
		fi

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
			if ! wget -q $my_show_progress --user-agent="wget $WEBI_UA" -c "$my_url" -O "$my_dl.part"; then
				echo >&2 "failed to download from $my_url"
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
			curl -fSL $my_show_progress -H "User-Agent: curl $WEBI_UA" "$my_url" -o "$my_dl.part"
		fi
		mv "$my_dl.part" "$my_dl"
		echo "Saved as $my_dl"
	}

	# detect which archives can be used
	webi_extract() {
		(
			cd "$WEBI_TMP"
			if [ "tar" = "$WEBI_EXT" ]; then
				echo "Extracting ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				tar xf "${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
			elif [ "tar.gz" = "$WEBI_EXT" ]; then
				echo "Extracting ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				tar xf "${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
			elif [ "zip" = "$WEBI_EXT" ]; then
				echo "Extracting ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				unzip "${WEBI_PKG_PATH}/$WEBI_PKG_FILE" >__unzip__.log
			elif [ "exe" = "$WEBI_EXT" ]; then
				echo "Moving ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				mv "${WEBI_PKG_PATH}/$WEBI_PKG_FILE" .
			elif [ "xz" = "$WEBI_EXT" ]; then
				echo "Inflating ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				unxz -c "${WEBI_PKG_PATH}/$WEBI_PKG_FILE" >"$(basename "$WEBI_PKG_FILE")"
			else
				# do nothing
				echo "Failed to extract ${WEBI_PKG_PATH}/$WEBI_PKG_FILE"
				exit 1
			fi
		)
	}

	# use 'pathman' to update $HOME/.config/envman/PATH.env
	webi_path_add() {
		# make sure that we don't recursively install pathman with webi
		my_path="$PATH"
		export PATH="$HOME/.local/bin:$PATH"

		# # install pathman if not already installed
		# if [ -z "$(command -v pathman)" ]; then
		# 	"$HOME/.local/bin/webi" pathman >/dev/null
		# fi

		export PATH="$my_path"

		# # in case pathman was recently installed and the PATH not updated
		# mkdir -p "$_webi_tmp"
		# # 'true' to prevent "too few arguments" output
		# # when there are 0 lines of stdout
		# "$HOME/.local/bin/pathman" add "$1" |
		# 	grep "export" 2>/dev/null \
		# 		>>"$_webi_tmp/.PATH.env" ||
		# 	true
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
		if [ -n "$WEBI_SINGLE" ] || [ "single" = "${1:-}" ]; then
			mkdir -p "$(dirname "$pkg_src_cmd")"
			mv ./"$PKG_NAME"-*/"$pkg_cmd_name"* "$pkg_src_cmd"
			# mv ./"$pkg_cmd_name"* "$pkg_src_cmd"
		else
			rm -rf "$pkg_src"
			mv ./"$PKG_NAME"-*"$pkg_cmd_name"* "$pkg_src"
			# mv ./"$pkg_cmd_name"* "$pkg_src"
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
		echo ""
		init_singbox
	}

	##
	##
	## BEGIN custom override functions from <package>/install.sh
	##
	##

	WEBI_SINGLE=true

	# if [ -z "${WEBI_WELCOME:-}" ]; then
	# 	echo ""
	# 	printf "Thanks for using webi to install '\e[32m%s\e[0m' on '\e[31m%s/%s\e[0m'.\n" "${WEBI_PKG:-}" "$(uname -s)" "$(uname -m)"
	# 	echo "Have a problem? Experience a bug? Please let us know:"
	# 	echo "        https://github.com/webinstall/webi-installers/issues"
	# 	echo ""
	# 	printf "\e[31mLovin'\e[0m it? Say thanks with a \e[34mStar on GitHub\e[0m:\n"
	# 	printf "        \e[32mhttps://github.com/webinstall/webi-installers\e[0m\n"
	# 	echo ""
	# fi

	__init_installer() {

		# do nothing - to satisfy parser prior to templating
		printf ""
		#!/bin/sh

		_sudo() {
			log="${WEBI_PKG_WORKDIR}/$WEBI_PKG.log"
			if [ "$OS" = "windows" ]; then
				if [[ $(sfc 2>&1 | tr -d '\0') =~ SCANNOW ]]; then
					nohup "${@}" >"$log" 2>&1 &
				else
					echo "权限不足,必须以管理员身份运行 Git Bash."
					echo "右键点击 Git Bash 图标 > 属性 > 兼容性 > 勾选以管理员身份运行此程序 > 确定"
					nohup "${@}" >"$log" 2>&1 &
				fi
			else
				if [[ $(id -u) -ne 0 ]]; then
					askPass
					echo "$PWORD" | nohup sudo -S "${@}" >"$log" 2>&1 &
				else
					nohup "${@}" >"$log" 2>&1 &
				fi
			fi
		}

		askPass() {
			if [ $EUID -ne 0 ]; then
				if [ ! -s "${WEBI_PKG_WORKDIR}/$WEBI_PKG.cache" ]; then
					while [ -z "${PWORD:-}" ]; do
						echo ""
						unset PWORD
						PWORD=
						echo -n "请输入 '$(id -u -n)' 用户的开机登录密码: " 1>&2
						while IFS= read -r -n1 -s char; do
							# Convert users key press to hexadecimal character code
							# Note a 'return' or EOL, will return a empty string
							#
							#code=$( echo -n "$char" | od -An -tx1 | tr -d ' \011' )
							code=${char:+$(printf '%02x' "'$char'")} # set to nothing for EOL

							case "$code" in
							'' | 0a | 0d) break ;; # EOL, newline, return
							08 | 7f)               # backspace or delete
								if [ -n "$PWORD" ]; then
									PWORD="$(echo "$PWORD" | sed 's/.$//')"
									echo -n $'\b \b' 1>&2
								fi
								;;
							15) # ^U or kill line
								echo -n "$PWORD" | sed 's/./\cH \cH/g' >&2
								PWORD=''
								;;
							[01]?) ;; # Ignore ALL other control characters
							*)
								PWORD="$PWORD$char"
								echo -n '*' 1>&2
								;;
							esac
						done
						echo
					done
					echo $PWORD >"${WEBI_PKG_WORKDIR}/$WEBI_PKG.cache"
					echo ""
				fi
				PWORD=$(cat "${WEBI_PKG_WORKDIR}/$WEBI_PKG.cache")
			fi
		}

		# detect if file is downloaded, and how to download it
		download() {
			# determine the url to download
			if [ -n "${1:-}" ]; then
				my_url="$1"
			fi

			# determine the location to download to
			if [ -n "${2:-}" ]; then
				my_dl="$2"
			fi

			if [ -n "${3:-}" ]; then
				my_name="$3"
			fi

			echo "Downloading $3 from $my_url"

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
				if ! wget -q $my_show_progress --user-agent="wget $WEBI_UA" -c "$my_url" -O "$my_dl.part"; then
					case $my_name in
					config)
						return 1
						;;
					*)
						echo >&2 "failed to download from $my_url"
						exit 1
						;;
					esac
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
				curl -fSL $my_show_progress -H "User-Agent: curl $WEBI_UA" "$my_url" -o "$my_dl.part"
			fi

			mv "$my_dl.part" "$my_dl"
			case $my_name in
			yacd)
				printf ""
				;;
			geoip)
				echo "Saved as $my_dl"
				echo ""
				;;
			geosite)
				echo "Saved as $my_dl"
				echo ""
				;;
			config)
				printf ""
				;;
			*)
				echo "Saved as $my_dl"
				echo ""
				;;
			esac
		}

		download_deps() {

			set +e
			find "${WEBI_PKG_WORKDIR}/yacd" -name "CNAME" -ctime +30 -ls -exec rm -f {} \; >/dev/null 2>&1
			find "${WEBI_PKG_WORKDIR}" -name "geoip.db" -ctime +7 -ls -exec rm -f {} \; >/dev/null 2>&1
			find "${WEBI_PKG_WORKDIR}" -name "geosite.db" -ctime +7 -ls -exec rm -f {} \; >/dev/null 2>&1
			set -e

			if [ ! -f "${WEBI_PKG_WORKDIR}/yacd/CNAME" ]; then
				download "https://ghproxy.com/https://github.com/yuumimi/yacd/releases/latest/download/yacd.tar.gz" "${WEBI_PKG_PATH}/yacd.tar.gz" "yacd"
				(cd "$WEBI_TMP" && tar xf "${WEBI_PKG_PATH}/yacd.tar.gz" && cp -f -r "public/" "${WEBI_PKG_WORKDIR}/yacd/" && echo "Saved as ${WEBI_PKG_WORKDIR}/yacd" && echo "")
			fi

			if [ ! -f "${WEBI_PKG_WORKDIR}/geoip.db" ]; then
				download "https://ghproxy.com/https://github.com/yuumimi/sing-geoip/releases/latest/download/geoip.db" "${WEBI_PKG_WORKDIR}/geoip.db" "geoip"
			fi

			if [ ! -f "${WEBI_PKG_WORKDIR}/geosite.db" ]; then
				download "https://ghproxy.com/https://github.com/yuumimi/sing-geosite/releases/latest/download/geosite.db" "${WEBI_PKG_WORKDIR}/geosite.db" "geosite"
			fi
		}

		download_config() {
			set +e
			if [ -n "${URL:-}" ]; then
				download "$URL" "${WEBI_PKG_WORKDIR}/config.tmp" "config"
			fi
			if [ -f "${WEBI_PKG_WORKDIR}/config.tmp" ]; then
				if "$pkg_dst_cmd" check -c "${WEBI_PKG_WORKDIR}/config.tmp" 2>&1; then

					case $OS in
					linux)
						if [ -z "${default_interface:-}" ]; then
							default_interface=$(ip route | awk '/default/ {print $5}' | head -n 1)
						fi
						if [ -n "${default_interface:-}" ]; then
							sed -i "s/\"auto_detect_interface\"\: true/\"default_interface\"\: \"$default_interface\"/g" "${WEBI_PKG_WORKDIR}/config.tmp"
						fi
						sed -i "s/\"mtu\"\: 9000/\"mtu\"\: 1500/g" "${WEBI_PKG_WORKDIR}/config.tmp"
						;;
					darwin)
						if [ -z "${default_interface:-}"]; then
							default_interface=$(route -n get default | awk '/interface/ {print $2}' | head -n 1)
						fi
						;;
					windows)
						if [ -z "${default_interface:-}"]; then
							default_interface=$(ipconfig | awk '/Ethernet adapter/ {gsub(/:/,"",$3); print $3}' | head -n 1)
						fi
						if [ -n "${set_system_proxy:-}" ]; then
							inbounds_tun=$(sed -n '/inbounds/=' "${WEBI_PKG_WORKDIR}/config.tmp")
							sed -i "$((inbounds_tun + 1)),$((inbounds_tun + 11))d" "${WEBI_PKG_WORKDIR}/config.tmp"
							sed -i "s/\"set_system_proxy\"\: false/\"set_system_proxy\"\: $set_system_proxy/g" "${WEBI_PKG_WORKDIR}/config.tmp"
						fi
						;;
					esac

					mv "${WEBI_PKG_WORKDIR}/config.tmp" "${WEBI_PKG_WORKDIR}/config.json"
					echo "Saved as ${WEBI_PKG_WORKDIR}/config.json"
					echo ""
				else
					rm -rf "${WEBI_PKG_WORKDIR}/config.tmp"
				fi
			fi
			set -e
		}

		singbox_start() {
			if [ -s "${WEBI_PKG_WORKDIR}/config.json" ]; then
				mtu=$(cat "${WEBI_PKG_WORKDIR}/config.json" | awk '/"mtu"/ {gsub(/,|"/,"",$2); print $2}')
				inet4_address=$(cat "${WEBI_PKG_WORKDIR}/config.json" | awk '/"inet4_address"/ {gsub(/,|"|\/.*/,"",$2); print $2}' | cut -d ':' -f 2)
				external_controller_port=$(cat "${WEBI_PKG_WORKDIR}/config.json" | awk '/"external_controller"/ {gsub(/,|"/,"",$2); print $2}' | cut -d ':' -f 2)
			else
				printf "sing-box 配置文件不存在("${WEBI_PKG_WORKDIR}/config.json"),请重试 => 稍后再试 => 更换网络后再试.\n\n"
				exit 1
			fi

			_sudo "$pkg_dst_cmd" run -D "$WEBI_PKG_WORKDIR"

			printf "\n\n正在启动 sing-box...\n\n"
			sleep 3
			if [ "$OS" = "windows" ]; then
				sleep 7
			fi
			cat "$log" | head -n 7
			echo ""
			case $OS in
			linux)
				tun=$(ip a | grep "${inet4_address:-}")
				;;
			darwin)
				tun=$(ifconfig | grep "${inet4_address:-}")
				_sudo networksetup -setdnsservers Wi-Fi 223.5.5.5
				_sudo dscacheutil -flushcache
				_sudo killall -HUP mDNSResponder
				;;
			windows)
				tun=$(ipconfig | grep "${inet4_address:-}")
				;;
			esac

			if [ -n "${tun:-}" ]; then
				printf "\e[36m****************************************************************\e[0m\n"
				printf "\e[36m*                                                              *\e[0m\n"
				printf "\e[36m*\e[0m    控制面板: \033[04m\e[36mhttp://127.0.0.1:9090/ui/#/proxies\e[0m              \e[36m*\e[0m\n"
				printf "\e[36m*                                                              *\e[0m\n"
				printf "\e[36m*\e[0m    在浏览器中打开控制面板测速后选择\e[33m有延迟\e[0m的节点              \e[36m*\e[0m\n"
				printf "\e[36m*                                                              *\e[0m\n"
				printf "\e[36m****************************************************************\e[0m\n"
				echo ""
				printf "\e[32m****************************************************************\e[0m\n"
				printf "\e[32m*                                                              *\e[0m\n"
				printf "\e[32m*\e[0m    sing-box 已在后台运行 \e[33m再次运行一键脚本可停止 sing-box\e[0m     \e[32m*\e[0m\n"
				printf "\e[32m*                                                              *\e[0m\n"
				printf "\e[32m*\e[0m    小技巧: 在此窗口中按一次或多次\e[33m 上方向键 \e[0m可显示一键脚本    \e[32m*\e[0m\n"
				printf "\e[32m*                                                              *\e[0m\n"
				printf "\e[32m****************************************************************\e[0m\n"
				echo ""
				echo ""
				echo ""
				exit 0
			else
				printf "\e[31msing-box 无法启动,请退出安全卫士/电脑管家等安全类软件后再试.\e[0m\n\n"
				rm -rf "$HOME/._cache"
				exit 1
			fi
		}

		singbox_stop() {
			if [ "$OS" = "windows" ]; then
				pid=$(ps aux | grep "[s]ing-box" | awk '{print $1}')
			else
				pid=$(ps aux | grep "[s]ing-box" | awk '{print $2}')
			fi
			if [ -n "${pid:-}" ]; then
				_sudo kill -9 $pid
				echo ""
				printf "\n\n正在停止 sing-box...\n\n"
				sleep 3
				if [ "$OS" = "windows" ]; then
					sleep 7
				fi
				if [ $? -eq 0 ]; then
					printf "\e[31m****************************************************************\e[0m\n"
					printf "\e[31m*                                                              *\e[0m\n"
					printf "\e[31m*\e[0m    sing-box 已经停止运行 \e[33m再次运行一键脚本可启动 sing-box\e[0m     \e[31m*\e[0m\n"
					printf "\e[31m*                                                              *\e[0m\n"
					printf "\e[31m*\e[0m    小技巧: 在此窗口中按一次或多次\e[33m 上方向键 \e[0m可显示一键脚本    \e[31m*\e[0m\n"
					printf "\e[31m*                                                              *\e[0m\n"
					printf "\e[31m****************************************************************\e[0m\n"
					echo ""
					echo ""
					echo ""
					exit 0
				else
					printf "\e[31msing-box 无法停止,请重启设备.\e[0m\n\n"
					exit 1
				fi
			fi
		}

		init_singbox() {
			download_deps
			download_config
			singbox_start
		}

	}

	__init_installer
	singbox_stop

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
		[ -n "${WEBI_SINGLE:-}" ] ||
		[ -n "${pkg_cmd_name:-}" ] ||
		[ -n "${pkg_dst_cmd:-}" ] ||
		[ -n "${pkg_dst_dir:-}" ] ||
		[ -n "${pkg_dst:-}" ] ||
		[ -n "${pkg_src_cmd:-}" ] ||
		[ -n "${pkg_src_dir:-}" ] ||
		[ -n "${pkg_src:-}" ]; then

		pkg_cmd_name="${pkg_cmd_name:-$PKG_NAME}"
		if [ "$OS" = "windows" ]; then
			pkg_ext_name='.exe'
		else
			pkg_ext_name=''
		fi

		if [ -n "$WEBI_SINGLE" ]; then
			pkg_dst_cmd="${pkg_dst_cmd:-$HOME/.local/bin/$pkg_cmd_name$pkg_ext_name}"
			pkg_dst="$pkg_dst_cmd" # "$(dirname "$(dirname $pkg_dst_cmd)")"

			pkg_src_cmd="${pkg_src_cmd:-$HOME/.local/opt/$pkg_cmd_name-v$WEBI_VERSION/bin/$pkg_cmd_name$pkg_ext_name}"
			pkg_src="$pkg_src_cmd" # "$(dirname "$(dirname $pkg_src_cmd)")"
		else
			pkg_dst="${pkg_dst:-$HOME/.local/opt/$pkg_cmd_name}"
			pkg_dst_cmd="${pkg_dst_cmd:-$pkg_dst/bin/$pkg_cmd_name$pkg_ext_name}"

			pkg_src="${pkg_src:-$HOME/.local/opt/$pkg_cmd_name-v$WEBI_VERSION}"
			pkg_src_cmd="${pkg_src_cmd:-$pkg_src/bin/$pkg_cmd_name$pkg_ext_name}"
		fi
		# this script is templated and these are used elsewhere
		# shellcheck disable=SC2034
		pkg_src_bin="$(dirname "$pkg_src_cmd")"
		# shellcheck disable=SC2034
		pkg_dst_bin="$(dirname "$pkg_dst_cmd")"

		if [ -n "$(command -v pkg_pre_install)" ]; then pkg_pre_install; else webi_pre_install; fi

		(
			cd "$WEBI_TMP"
			echo "Installing to $pkg_src_cmd"
			if [ -n "$(command -v pkg_install)" ]; then pkg_install; else webi_install; fi
			chmod a+x "$pkg_src"
			chmod a+x "$pkg_src_cmd"
			if [ -z "$("$pkg_src_cmd" version)" ]; then
				rm -rf "$pkg_src"
				rm -rf "$pkg_src_cmd"
				WEBI_PKG_FILE="${PKG_NAME}-${WEBI_VERSION}-${WEBI_OS}-amd64v3.${WEBI_EXT}"
				WEBI_PKG_URL="${WEBI_HOST}/${WEBI_RELEASES}/${WEBI_TAG}/${WEBI_PKG_FILE}"
				webi_pre_install
				webi_install
				chmod a+x "$pkg_src"
				chmod a+x "$pkg_src_cmd"
			fi
		)

		webi_link

		_webi_enable_exec
		(
			cd "$WEBI_TMP"
			if [ -n "$(command -v pkg_post_install)" ]; then pkg_post_install; else webi_post_install; fi
		)

		(
			cd "$WEBI_TMP"
			if [ -n "$(command -v pkg_done_message)" ]; then pkg_done_message; else _webi_done_message; fi
		)

		echo ""
	fi

	webi_path_add "$HOME/.local/bin"

	# cleanup the temp directory
	rm -rf "$WEBI_TMP"

	# See? No magic. Just downloading and moving files.

}

init_arch() {
	ARCH=$(uname -m)
	case $ARCH in
	arm64 | aarch64) ARCH="arm64" ;;
	x86_64 | amd64 | x64) ARCH="amd64" ;;
	i386 | i86pc | x86 | i686) ARCH="386" ;;
	armv7*) ARCH="armv7" ;;
	s390x) ARCH="s390x" ;;
	*)
		echo "Architecture ${ARCH} is not supported by this installation script"
		exit 1
		;;
	esac
}

init_os() {
	OS=$(uname | tr '[:upper:]' '[:lower:]')
	case "$OS" in
	darwin) OS='darwin' ;;
	linux) OS='linux' ;;
	mingw* | msys* | cygwin*) OS='windows' ;;
	*)
		echo "OS ${OS} is not supported by this installation script"
		exit 1
		;;
	esac
}

init_arch
init_os

args=$(awk 'BEGIN { for(i = 1; i < ARGC; i++) print ARGV[i] }' "$@")

if echo "$args" | grep -E '^https:\/\/' >/dev/null; then
	URL=$(echo "$args" | grep -E '^https:\/\/')
fi

if echo "$args" | grep -E '^version=' >/dev/null; then
	VERSION=$(echo "$args" | grep -E '^version=' | cut -d'=' -f2)
fi

if echo "$args" | grep -E '^default_interface=' >/dev/null; then
	default_interface=$(echo "$args" | grep -E '^default_interface=' | cut -d'=' -f2)
fi

if echo "$args" | grep -E '^set_system_proxy=' >/dev/null; then
	set_system_proxy=$(echo "$args" | grep -E '^set_system_proxy=' | cut -d'=' -f2)
fi

__bootstrap_webi
