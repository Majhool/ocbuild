#!/bin/bash

unset WORKSPACE
unset PACKAGES_PATH

BUILDDIR=$(pwd)

if [ "$NEW_BUILDSYSTEM" = "" ]; then
  NEW_BUILDSYSTEM=0
fi

if [ "$OFFLINE_MODE" = "" ]; then
  OFFLINE_MODE=0
fi

is_array()
{
    # 检测参数是否为数组，成功时返回1，否则返回0
    [ -z "$1" ] && echo 0
    if [ -n "$BASH" ]; then
      declare -p "${1}" 2> /dev/null | grep 'declare \-a' >/dev/null && echo 1
    fi
    echo 0
}

prompt() {
  echo "$1"
  if [ "$FORCE_INSTALL" != "1" ]; then
    read -rp "输入 [Y]es 继续: " v
    if [ "$v" != "Y" ] && [ "$v" != "y" ]; then
      exit 1
    fi
  fi
}

setcommitauthor() {
  git config user.name ocbuild
  git config user.email ocbuild@acidanthera.local
  git config commit.gpgsign false
}

updaterepo() {
  if [ ! -d "$2" ]; then
   echo "开始下载/更新UDK资源,资源文件较大，根据你的网速会有不同的完成速度，请耐心等候..."
    gitme clone "$1" -b "$3" --depth=1 "$2" || exit 1
  fi
  pushd "$2" >/dev/null || exit 1
  git pull --rebase --autostash
  if [ "$2" != "UDK" ] && [ "$(unamer)" != "Windows" ]; then
    sym=$(find . -not -type d -not -path "./coreboot/*" -not -path "./UDK/*" -exec file "{}" ";" | grep CRLF)
    if [ "${sym}" != "" ]; then
      echo "名为 $2 的存储库 $1 包含CRLF行结尾"
      echo "$sym"
      exit 1
    fi
  fi
  if [ "$2" = "UDK" ] && [ "$DISCARD_SUBMODULES" != "" ] && [ ! -f submodules.ready ]; then
    setcommitauthor
    for module_to_discard in "${DISCARD_SUBMODULES[@]}" ; do
      git rm "${module_to_discard}"
    done
    git commit -m "Discarded submodules"
    touch submodules.ready
  fi
  echo "更新UDK子模块内容,资源文件较大，根据你的网速会有不同的完成速度，请耐心等候..."
  git submodule update --init --recommend-shallow || exit 1
  popd >/dev/null || exit 1
}

abortbuild() {
  echo "构建失败!"
  tail -120 build.log
  exit 1
}

pingme() {
  local timeout=200 # in 30s
  local count=0
  local cmd_pid=$1
  shift

  while [ $count -lt $timeout ]; do
    count=$(( count + 1 ))
    printf "."
    sleep 30
  done

  ## ShellCheck Exception(s)
  ## https://github.com/koalaman/shellcheck/wiki/SC2028
  ## https://github.com/koalaman/shellcheck/wiki/SC2145
  # shellcheck disable=SC2028,SC2145
  echo "\n\033[31;1m超时了. 终止... $@.\033[0m"
  kill -9 "${cmd_pid}"
  }

star(){
  local cmd_pid=$1
  local cmd_name=$2
  local i=0
  local arr=("|" "/" "-" "\\")
  local dots=""
  trap 'exit 0' SIGTERM SIGINT
  
  while true; do
    if ! ps -p $cmd_pid > /dev/null 2>&1; then
      break
    fi
    
    let index=i%4
    printf "\r[%s] %s %s" "${arr[$index]}" "$cmd_name" "$dots"
    sleep 0.2
    let i++
    if [ $i -eq 4 ]; then
      dots="$dots."
      if [ ${#dots} -gt 3 ]; then
        dots=""
      fi
      i=0
    fi
  done
  printf "\r%s\r" "$(printf ' %.0s' {1..80})"
}

buildme() {
  local cmd_pid
  local mon_pid
  local result
  local build_cmd="build $*"

  # 设置信号处理
  trap 'kill -TERM $cmd_pid $mon_pid 2>/dev/null; exit 1' INT TERM

  # 启动构建进程
  $build_cmd &>build.log &
  cmd_pid=$!

  # 启动进度显示
  star $cmd_pid "正在编译" &
  mon_pid=$!

  # 等待构建完成
  wait $cmd_pid 2>/dev/null
  result=$?

  # 清理进度显示
  if ps -p $mon_pid > /dev/null 2>&1; then
    kill -TERM $mon_pid 2>/dev/null
  fi

  return $result
}

gitme() {
  local cmd_pid
  local mon_pid
  local result
  local git_cmd="git $*"

  # 设置信号处理
  trap 'kill -TERM $cmd_pid $mon_pid 2>/dev/null; exit 1' INT TERM

  # 启动 git 进程
  $git_cmd &>/dev/null &
  cmd_pid=$!

  # 启动进度显示
  star $cmd_pid "Git" &
  mon_pid=$!

  # 等待 git 完成
  wait $cmd_pid 2>/dev/null
  result=$?

  # 清理进度显示
  if ps -p $mon_pid > /dev/null 2>&1; then
    kill -TERM $mon_pid 2>/dev/null
  fi

  return $result
}

makeme() {
  local cmd_pid
  local mon_pid
  local result
  local make_cmd="make $*"

  # 设置信号处理
  trap 'kill -TERM $cmd_pid $mon_pid 2>/dev/null; exit 1' INT TERM

  # 启动 make 进程
  $make_cmd &>make.log &
  cmd_pid=$!

  # 启动进度显示
  star $cmd_pid "正在构建" &
  mon_pid=$!

  # 等待 make 完成
  wait $cmd_pid 2>/dev/null
  result=$?

  # 清理进度显示
  if ps -p $mon_pid > /dev/null 2>&1; then
    kill -TERM $mon_pid 2>/dev/null
  fi

  return $result
}

symlink() {
  if [ "$(unamer)" = "Windows" ]; then
    # This requires extra permissions.
    # cmd <<< "mklink /D \"$2\" \"${1//\//\\}\"" > /dev/null
    rm -rf "$2"
    mkdir -p "$2" || exit 1
    for i in "$1"/* ; do
      if [ "$(echo "${i}" | grep "$(basename "$(pwd)")")" != "" ]; then
        continue
      fi
      cp -r "$i" "$2" || exit 1
    done
  elif [ ! -d "$2" ]; then
    ln -s "$1" "$2" || exit 1
  fi
}

unamer() {
  NAME="$(uname)"

  if [ "$(echo "${NAME}" | grep MINGW)" != "" ] || [ "$(echo "${NAME}" | grep MSYS)" != "" ]; then
    echo "Windows"
  else
    echo "${NAME}"
  fi
}

echo "在 $(unamer) 平台上构建"

if [ "$(unamer)" = "Windows" ]; then
  cmd <<< 'chcp 437'
  export PYTHON_COMMAND="python"
fi

if [ "${SELFPKG}" = "" ]; then
  echo "您需要设置SELFPKG变量!"
  exit 1
fi

if [ "${SELFPKG_DIR}" = "" ]; then
  SELFPKG_DIR="${SELFPKG}"
fi

if [ "${BUILDDIR}" != "$(printf "%s\n" "${BUILDDIR}")" ] ; then
  echo "EDK2构建系统可能仍然不能支持带空格的目录!"
  exit 1
fi

if [ "$(which git)" = "" ]; then
  echo "缺少 git 命令, 请先安装它!"
  exit 1
fi

if [ "$(which zip)" = "" ]; then
  echo "缺少 zip 命令, 请先安装它!"
  exit 1
fi

if [ "$(unamer)" = "Darwin" ]; then
  if [ "$(which clang)" = "" ] || [ "$(clang -v 2>&1 | grep "no developer")" != "" ] || [ "$(git -v 2>&1 | grep "no developer")" != "" ]; then
    echo "缺少xcode工具，请先安装它们!"
    exit 1
  fi
fi

# On Windows nasm and python may not be in PATH.
if [ "$(unamer)" = "Windows" ]; then
  export PATH="/c/Python38:$PATH:/c/Program Files/NASM:/c/tools/ASL"
fi

if [ "$(nasm -v)" = "" ] || [ "$(nasm -v | grep Apple)" != "" ]; then
  echo "缺少或不兼容的nasm，请手工安装它!"
  echo "从仓库下载最新的nasm"
  echo "当前路径: $PATH -- $(which nasm)"
  # On Darwin we can install prebuilt nasm. On Linux let users handle it.
  if [ "$(unamer)" = "Darwin" ]; then
    prompt "自动安装最新测试版本?"
  else
    exit 1
  fi
  pushd /tmp >/dev/null || exit 1
  rm -rf nasm-mac64.zip
  echo "开始下载nasm...."
  curl -OLs "https://github.com/acidanthera/ocbuild/raw/master/external/nasm-mac64.zip" || exit 1
  nasmzip=$(cat nasm-mac64.zip)
  rm -rf nasm-*
  echo "开始下载nasm...."
  curl -OLs "https://github.com/acidanthera/ocbuild/raw/master/external/${nasmzip}" || exit 1
  unzip -q "${nasmzip}" nasm*/nasm nasm*/ndisasm || exit 1
  sudo mkdir -p /usr/local/bin || exit 1
  sudo mv nasm*/nasm /usr/local/bin/ || exit 1
  sudo mv nasm*/ndisasm /usr/local/bin/ || exit 1
  rm -rf "${nasmzip}" nasm-*
  popd >/dev/null || exit 1
fi

if [ "$(iasl -v)" = "" ]; then
  echo "缺少iasl!"
  echo "从https://acpica.org/downloads下载最新的iasl"
  # On Darwin we can install prebuilt iasl. On Linux let users handle it.
  if [ "$(unamer)" = "Darwin" ]; then
    prompt "是否自动安装上次测试的版本？"
  else
    exit 1
  fi
  pushd /tmp >/dev/null || exit 1
  rm -rf iasl-macosx.zip
  curl -OLs "https://github.com/acidanthera/ocbuild/raw/master/external/iasl-macosx.zip" || exit 1
  iaslzip=$(cat iasl-macosx.zip)
  rm -rf iasl
  curl -OLs "https://github.com/acidanthera/ocbuild/raw/master/external/${iaslzip}" || exit 1
  unzip -q "${iaslzip}" iasl || exit 1
  sudo mkdir -p /usr/local/bin || exit 1
  sudo mv iasl /usr/local/bin/ || exit 1
  rm -rf "${iaslzip}" iasl
  popd >/dev/null || exit 1
fi

# On Darwin we need mtoc. Only for XCODE5, but do not care for now.
if [ "$(unamer)" = "Darwin" ]; then
  valid_mtoc=false
else
  valid_mtoc=true
fi

MTOC_LATEST_VERSION="1.0.3"

if [ "$(which mtoc)" != "" ]; then
  mtoc_version=$(mtoc --version)
  if [ "${mtoc_version}" = "${MTOC_LATEST_VERSION}" ]; then
    valid_mtoc=true
  elif [ "${IGNORE_MTOC_VERSION}" = "1" ]; then
    echo "强制使用未知的mtoc版本,由于 IGNORE_MTOC_VERSION=1"
    valid_mtoc=true
  else
    echo "发现安装到不兼容的mtoc ${mtoc_path}!"
    echo "预期的SHA-256: ${MTOC_HASH}"
    echo "找到的SHA-256:    ${mtoc_hash_user}"
    echo "提示:重新安装此mtoc或使用 IGNORE_MTOC_VERSION=1，风险自负."
  fi
fi

if ! $valid_mtoc; then
  echo "mtoc缺失或不兼容!"
  echo "要构建mtoc，请遵循以下步骤: https://github.com/tianocore/tianocore.github.io/wiki/Xcode#mac-os-x-xcode"
  prompt "自动安装预构建的mtoc？"
  pushd /tmp >/dev/null || exit 1
  rm -f mtoc ocmtoc-${MTOC_LATEST_VERSION}-RELEASE.zip
  echo "开始下载mtoc......"
  curl -OL "https://github.com/acidanthera/ocmtoc/releases/download/${MTOC_LATEST_VERSION}/ocmtoc-${MTOC_LATEST_VERSION}-RELEASE.zip" || exit 1
  unzip -q "ocmtoc-${MTOC_LATEST_VERSION}-RELEASE.zip" mtoc || exit 1
  echo "请输入管理员密码:"
  sudo mkdir -p /usr/local/bin || exit 1
  sudo rm -f /usr/local/bin/mtoc /usr/local/bin/mtoc.NEW || exit 1
  sudo cp mtoc /usr/local/bin/mtoc || exit 1
  popd >/dev/null || exit 1

  mtoc_version=$(mtoc --version)
  if [ "${mtoc_version}" != "${MTOC_LATEST_VERSION}" ]; then
    echo "无法安装兼容版本的MTOC!"
    echo "预期版本: ${MTOC_LATEST_VERSION}"
    echo "找到的版本:    ${mtoc_version}"
    exit 1
  fi
fi

if [ "$RELPKG" = "" ]; then
  RELPKG="$SELFPKG"
fi

if [ -n "$ARCHS" ] && [ "$(is_array ARCHS)" = "0" ]; then
  IFS=', ' read -r -a ARCHS <<< "$ARCHS"
fi

if [ -n "$ARCHS_EXT" ] && [ "$(is_array ARCHS_EXT)" = "0" ]; then
  IFS=', ' read -r -a ARCHS_EXT <<< "$ARCHS_EXT"
fi

if [ -n "$TOOLCHAINS" ] && [ "$(is_array TOOLCHAINS)" = "0" ]; then
  IFS=', ' read -r -a TOOLCHAINS <<< "$TOOLCHAINS"
fi

if [ -n "$TARGETS" ] && [ "$(is_array TARGETS)" = "0" ]; then
  IFS=', ' read -r -a TARGETS <<< "$TARGETS"
fi

if [ -n "$RTARGETS" ] && [ "$(is_array RTARGETS)" = "0" ]; then
  IFS=', ' read -r -a RTARGETS <<< "$RTARGETS"
fi

if [ -n "$BUILD_ARGUMENTS" ] && [ "$(is_array BUILD_ARGUMENTS)" = "0" ]; then
  IFS=', ' read -r -a BUILD_ARGUMENTS <<< "$BUILD_ARGUMENTS"
fi

if [ "${ARCHS[*]}" = "" ]; then
  ARCHS=('X64')
fi

if [ "${TOOLCHAINS[*]}" = "" ]; then
  if [ "$(unamer)" = "Darwin" ]; then
    TOOLCHAINS=('XCODE5')
  elif [ "$(unamer)" = "Windows" ]; then
    TOOLCHAINS=('VS2019')
  else
    TOOLCHAINS=('CLANGPDB' 'GCC')
  fi
fi

if [ "${TARGETS[*]}" = "" ]; then
  TARGETS=('DEBUG' 'RELEASE')
elif [ "${RTARGETS[*]}" = "" ]; then
  RTARGETS=("${TARGETS[@]}")
fi

if [ "${RTARGETS[*]}" = "" ]; then
  RTARGETS=('DEBUG' 'RELEASE')
fi

if [ "${BUILD_ARGUMENTS[*]}" = "" ]; then
  BUILD_ARGUMENTS=()
fi

if [ -z "${SKIP_TESTS}" ]; then
  SKIP_TESTS=0
fi
if [ -z "${SKIP_BUILD}" ]; then
  SKIP_BUILD=0
fi
if [ -z "${SKIP_PACKAGE}" ]; then
  SKIP_PACKAGE=0
fi

MODE=""

while true; do
  if [ "$1" == "--skip-tests" ]; then
    SKIP_TESTS=1
    shift
  elif [ "$1" == "--skip-build" ]; then
    SKIP_BUILD=1
    shift
  elif [ "$1" == "--skip-package" ]; then
    SKIP_PACKAGE=1
    shift
  elif [ "$1" == "--build-extra" ]; then
    shift
    BUILD_STRING="$1"
    # shellcheck disable=SC2206
    BUILD_ARGUMENTS+=($BUILD_STRING )
    shift
  else
    break
  fi
done

if [ "$1" != "" ]; then
  MODE="$1"
  shift
fi

echo "主工具链是: ${TOOLCHAINS[0]} |  架构：${ARCHS[0]}"

if [ ! -d "Binaries" ]; then
  mkdir Binaries || exit 1
fi

if [ "$NEW_BUILDSYSTEM" != "1" ]; then
  if [ ! -f UDK/UDK.ready ]; then
    rm -rf UDK

    if [ "$(unamer)" != "Windows" ]; then
      sym=$(find . -not -type d -not -path "./coreboot/*" -exec file "{}" ";" | grep CRLF)
      if [ "${sym}" != "" ]; then
        echo "错误：存储库中的以下文件 CRLF 行结尾:"
        echo "$sym"
        exit 1
      fi
    fi
  fi
fi

if [ "$NEW_BUILDSYSTEM" != "1" ]; then
  if [ "$OFFLINE_MODE" != "1" ]; then
    updaterepo "https://github.com/acidanthera/audk" UDK master || exit 1
  else
    echo "在离线模式下工作。跳过 UDK 更新"
  fi
fi
cd UDK || exit 1
HASH=$(git rev-parse origin/master)

if [ "$DISCARD_PACKAGES" != "" ]; then 
  for package_to_discard in "${DISCARD_PACKAGES[@]}" ; do
    if [ -d "${package_to_discard}" ]; then
      rm -rf "${package_to_discard}"
    fi
  done
fi

if [ "$NEW_BUILDSYSTEM" != "1" ]; then
  if [ -d ../Patches ]; then
    if [ ! -f patches.ready ]; then
      setcommitauthor
      for i in ../Patches/* ; do
        git apply --ignore-whitespace "$i" >/dev/null || exit 1
        git add .
        git commit -m "Applied patch $i" >/dev/null || exit 1
      done
      touch patches.ready
    fi
  fi
fi

deps="${#DEPNAMES[@]}"
for (( i=0; i<deps; i++ )) ; do
  echo "正在更新 ${DEPNAMES[$i]}"
  if [ "$OFFLINE_MODE" != "1" ]; then
    updaterepo "${DEPURLS[$i]}" "${DEPNAMES[$i]}" "${DEPBRANCHES[$i]}" || exit 1
  else
    echo "在离线模式下工作. 跳过 ${DEPNAMES[$i]} 更新"
  fi

done

if [ "$NEW_BUILDSYSTEM" != "1" ]; then
  # Allow building non-self packages.
  if [ ! -e "${SELFPKG_DIR}" ]; then
    symlink .. "${SELFPKG_DIR}" || exit 1
  fi
fi
echo "正在设置EDK工作空间..."
. ./edksetup.sh >/dev/null || exit 1


if [ "$(unamer)" = "Windows" ]; then
  # Configure Visual Studio environment. Requires:
  # 1. choco install vswhere microsoft-build-tools visualcpp-build-tools nasm zip
  # 2. iasl in PATH for MdeModulePkg
  tools="${EDK_TOOLS_PATH}"
  tools="${tools//\//\\}"
  # For Travis CI
  tools="${tools/\\c\\/C:\\}"
  # For GitHub Actions
  tools="${tools/\\d\\/D:\\}"
  echo "将 EDK_TOOLS_PATH 从 ${EDK_TOOLS_PATH} 扩展到 ${tools}"
  export EDK_TOOLS_PATH="${tools}"
  export BASE_TOOLS_PATH="${tools}"
  VS2019_BUILDTOOLS=$(vswhere -latest -version '[16.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
  VS2019_BASEPREFIX="${VS2019_BUILDTOOLS}\\VC\\Tools\\MSVC\\"
  # Intended to use ls here to get first entry.
  # REF: https://github.com/koalaman/shellcheck/wiki/SC2012
  # shellcheck disable=SC2012
  cd "${VS2019_BASEPREFIX}" || exit 1
  # Incorrect diagnostic due to action.
  # REF: https://github.com/koalaman/shellcheck/wiki/SC2035
  # shellcheck disable=SC2035
  VS2019_DIR="$(find * -maxdepth 0 -type d -print -quit)"
  if [ "${VS2019_DIR}" = "" ]; then
    echo "没有VS2019 MSVC编译器"
    exit 1
  fi
  cd - || exit 1
  export VS2019_PREFIX="${VS2019_BASEPREFIX}${VS2019_DIR}\\"

  WINSDK_BASE="/c/Program Files (x86)/Windows Kits/10/bin"
  if [ -d "${WINSDK_BASE}" ]; then
    for dir in "${WINSDK_BASE}"/*/; do
      if [ -f "${dir}x86/rc.exe" ]; then
        WINSDK_PATH_FOR_RC_EXE="${dir}x86"
        WINSDK_PATH_FOR_RC_EXE="${WINSDK_PATH_FOR_RC_EXE//\//\\}"
        WINSDK_PATH_FOR_RC_EXE="${WINSDK_PATH_FOR_RC_EXE/\\c\\/C:\\}"
        break
      fi
    done
  fi
  if [ "${WINSDK_PATH_FOR_RC_EXE}" != "" ]; then
    export WINSDK_PATH_FOR_RC_EXE
  else
    echo "无法找到rc.exe"
    exit 1
  fi
  BASE_TOOLS="$(pwd)/BaseTools"
  export PATH="${BASE_TOOLS}/Bin/Win32:${BASE_TOOLS}/BinWrappers/WindowsLike:$PATH"
  # Extract header paths for cl.exe to work.
  eval "$(python -c '
import sys, os, subprocess
import distutils.msvc9compiler as msvc
msvc.find_vcvarsall=lambda _: sys.argv[1]
envs=msvc.query_vcvarsall(sys.argv[2])
for k,v in envs.items():
    k = k.upper()
    v = ":".join(subprocess.check_output(["cygpath","-u",p]).decode("ascii").rstrip() for p in v.split(";"))
    v = v.replace("'\''",r"'\'\\\'\''")
    print("export %(k)s='\''%(v)s'\''" % locals())
' "${VS2019_BUILDTOOLS}\\Common7\\Tools\\VsDevCmd.bat" '-arch=amd64')"
fi

if [ "$NEW_BUILDSYSTEM" != "1" ]; then
  if [ "$SKIP_TESTS" != "1" ]; then
    echo "测试..."
    if [ "$(unamer)" = "Windows" ]; then
      # Normal build similar to Unix.
      cd BaseTools || exit 1
      nmake        || exit 1
      cd ..        || exit 1
    else
      echo "构建EDK环境...."
      makeme -C BaseTools -j || exit 1
    fi
    touch UDK.ready
      echo -e "\n构建完成!!"
      echo -e "----------------------------------------------------------------\n"
  fi
fi

if [ "$SKIP_BUILD" != "1" ]; then
  echo "开始编译..."
  for i in "${!ARCHS[@]}" ; do
    for toolchain in "${TOOLCHAINS[@]}" ; do
      for target in "${TARGETS[@]}" ; do
        if [ "$MODE" = "" ] || [ "$MODE" = "$target" ]; then
          if [ "${ARCHS_EXT[i]}" == "" ]; then
            echo -e "使用 ${toolchain} 工具链和 $BUILD_STRING 标志在 $target 版本中为 ${ARCHS[i]} 架构构建 ${SELFPKG_DIR}/${SELFPKG}.dsc ..."
            buildme -a "${ARCHS[i]}" -b "$target" -t "${toolchain}" -p "${SELFPKG_DIR}/${SELFPKG}.dsc" "${BUILD_ARGUMENTS[@]}" || abortbuild
          else
            echo "在 $target 中使用 ${toolchain} 工具链和 $BUILD_STRING 标志为 ${ARCHS_EXT[i]} 使用额外的架构 ${ARCHS_EXT[i]} 构建 ${SELFPKG_DIR}/${SELFPKG}.dsc  ..."
            buildme -a "${ARCHS_EXT[i]}" -a "${ARCHS[i]}" -b "$target" -t "${toolchain}" -p "${SELFPKG_DIR}/${SELFPKG}.dsc" "${BUILD_ARGUMENTS[@]}" || abortbuild
          fi
          echo -e "\n编译完成!!"
          echo -e "----------------------------------------------------------------"
        fi
      done
    done
  done
fi

cd .. || exit 1
echo -e "****************************************************************\n"
if [ "$(type -t package)" = "function" ]; then
  if [ "$SKIP_PACKAGE" != "1" ]; then
    echo "开始打包..."
    if [ "$NO_ARCHIVES" != "1" ]; then
      rm -f Binaries/*.zip
    fi
    for rtarget in "${RTARGETS[@]}" ; do
      for toolchain in "${TOOLCHAINS[@]}" ; do
        if [ "$PACKAGE" = "" ] || [ "$PACKAGE" = "$rtarget" ]; then
          if [ "${#TOOLCHAINS[@]}" -eq 1 ]; then
            name="${rtarget}"
          else
            name="${toolchain}-${rtarget}"
          fi
          package "UDK/Build/${RELPKG}/${rtarget}_${toolchain}/${ARCHS[0]}" "${name}" "${HASH}" || exit 1
          if [ "$NO_ARCHIVES" != "1" ]; then
            cp "UDK/Build/${RELPKG}/${rtarget}_${toolchain}/${ARCHS[0]}"/*.zip Binaries || echo skipping
          fi
        fi
      done
    done
  fi
fi
