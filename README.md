<img src="docs/images/icon.png" width="96" alt="MacDashboard icon">

# MacDashboard

**English** · [한국어](#한국어)

A macOS menu bar app that shows system status and AI usage limits at a glance (Swift / SwiftUI, macOS 26+).

![Menu bar](docs/images/menubar.png)

---

## English

| System dashboard | Usage limits |
|---|---|
| ![System dashboard](docs/images/en/dashboard.png) | ![Usage limits](docs/images/en/usage.png) |

| Local AI speed |
|---|
| ![Local AI speed](docs/images/en/local-ai.png) |

> The screenshots were taken with IP address and account email display turned off.

### Features
- **System popover**: CPU (user/system, per core, temperature), GPU (renderer/tiler, temperature), memory (app/wired/compressed/swap, memory pressure), internal and external disks (capacity, read/write speed), network (speed, IP, VPN indicator), fan rpm
- **Usage popover**: 5-hour and weekly usage for Claude, ChatGPT (Codex) and Gemini (Antigravity), with time until each limit resets
- **One-click connect**: if Claude Code or Codex isn't installed or signed in, its card shows **Connect**. It opens Terminal, installs the CLI if needed (Homebrew, or the official installer / npm), starts the sign-in, and the card fills in by itself when you finish
- **Antigravity setup guide**: if the Antigravity CLI isn't installed or signed in, the Gemini card shows the steps (Homebrew recommended, with copy buttons and links to other install options). Install it your way; MacDashboard connects on its own a few seconds after the CLI works
- **Local AI speed**: finds LM Studio, Ollama or a llama.cpp server running on this Mac and shows the loaded model (format, quantization, context, size), generation speed, time to first token and prompt processing speed. **Quick test** and **Context sweep** (≈1k / 8k / 32k-token inputs) benchmark the model; with LM Studio, requests from any app are recorded too (timings only, never text). It also flags memory pressure and shows GPU load, swap and system power. The menu bar shows the latest typical speed (`LLM 16.9`)
- **Settings**: choose menu bar items, pin one or more services to the badge, switch between used and remaining, refresh interval, hide IP and account emails, launch at login
- **Languages**: English and Korean. Follows the system language by default; change it in Settings → General → Language

The badges on the left show usage for each pinned service (Claude, ChatGPT and Gemini above, each marked with its logo in color); the items on the right show CPU, temperature, memory, SSD and network speed. Pin or unpin services with the pin button on each card or in Settings.

### Install (Release)
1. Download `MacDashboard-<version>.zip` from [Releases](https://github.com/ksemperor97/MacDashboard/releases), unzip it, and move `MacDashboard.app` to `/Applications`.
2. The app is ad-hoc signed and not notarized by Apple, so macOS blocks it the first time. Try to open it once, then click **System Settings → Privacy & Security → "Open Anyway"**. Or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacDashboard.app
   ```

**Requirements**: Apple Silicon Mac, macOS 26 (Tahoe) or later. AI usage comes from the Claude Code / Codex / Antigravity CLI accounts signed in on that Mac; services you don't use can be turned off in Settings. Temperatures and fans have only been checked on an M5 Max.

### Build from source
```bash
scripts/build_app.sh            # creates build/MacDashboard.app
scripts/build_app.sh --install  # installs to /Applications
scripts/build_app.sh --zip      # creates the release zip
```
Builds with Command Line Tools alone (Swift 6.4); Xcode is not required. Signing is ad-hoc.

### Data sources
| Item | Source |
|---|---|
| CPU / memory | Mach `host_processor_info`, `host_statistics64`, `sysctl` (`kern.memorystatus_vm_pressure_level`) |
| Disk | `volumeAvailableCapacityForImportantUsage` (same value as Finder), IOBlockStorageDriver statistics |
| External disks | DiskArbitration selects external physical disks only, `statfs` reads capacity. Network and FUSE mounts are skipped. Rescanned every 30 s and on mount/unmount |
| Network | `NET_RT_IFLIST2` 64-bit counters, SystemConfiguration. With a VPN, shows the physical interface that carries the traffic |
| GPU | IOAccelerator `PerformanceStatistics` |
| Temperature / fans | AppleSMC (`Tp*`, `Tg*`, `F*Ac`), IOHIDEventSystem (no root needed) |
| Claude | OAuth token Claude Code stores in the keychain → `api.anthropic.com/api/oauth/usage` |
| ChatGPT | `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`, falling back to the latest record in `~/.codex/sessions` |
| Gemini | `agy -p /quota --output-format json` (Antigravity CLI; does not consume quota) |

The AI usage APIs are undocumented internal endpoints and may change. Tokens are only read; the app never refreshes or stores them elsewhere.

### Diagnostic options
```bash
build/MacDashboard.app/Contents/MacOS/MacDashboard --dump-system     # print system metrics 3 times
build/MacDashboard.app/Contents/MacOS/MacDashboard --dump-usage      # print AI usage results
build/MacDashboard.app/Contents/MacOS/MacDashboard --probe-sensors   # list SMC/HID temperature and fan sensors
open build/MacDashboard.app --args --open system|usage|settings     # open a panel right after launch
build/MacDashboard.app/Contents/MacOS/MacDashboard --render-logos out.png  # render the service logos to a PNG
```

The app icon is generated by `scripts/make_icon.py` (needs Pillow) into `Resources/AppIcon.icns`.

### Credits
Service logo path data comes from [Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT License). Claude, ChatGPT/OpenAI and Gemini logos are trademarks of their respective owners and are used only to label each service's usage; this project is not affiliated with them.

---

## 한국어

메뉴 막대에서 시스템 상태와 AI 사용 한도를 한 번에 보는 macOS 앱 (Swift / SwiftUI, macOS 26+).

| 시스템 대시보드 | 사용 한도 |
|---|---|
| ![시스템 대시보드](docs/images/ko/dashboard.png) | ![사용 한도](docs/images/ko/usage.png) |

| 로컬 AI 속도 |
|---|
| ![로컬 AI 속도](docs/images/ko/local-ai.png) |

> 스크린샷은 설정에서 IP 주소와 계정 이메일 표시를 끈 상태예요.

### 기능
- **시스템 팝오버**: CPU(사용자/시스템, 코어별, 온도), GPU(렌더러/타일러, 온도), 메모리(앱/와이어드/압축/스왑, 메모리 압력), 내장·외장 디스크(용량, 읽기/쓰기 속도), 네트워크(속도, IP, VPN 여부), 팬 rpm
- **사용 한도 팝오버**: Claude, ChatGPT(Codex), Gemini(Antigravity)의 5시간/주간 사용률과 초기화까지 남은 시간
- **원클릭 연결**: Claude Code나 Codex가 설치되지 않았거나 로그인되지 않았으면 카드에 **연결하기** 버튼이 나와요. 누르면 터미널이 열리고, 필요하면 CLI를 설치한 뒤(Homebrew, 또는 공식 설치 스크립트/npm) 로그인을 시작해요. 로그인을 마치면 카드가 알아서 갱신돼요
- **Antigravity 설치 안내**: Antigravity CLI가 설치되지 않았거나 로그인되지 않았으면 Gemini 카드에 설치·로그인 단계를 보여줘요(Homebrew 권장, 복사 버튼과 다른 설치 방법 링크 포함). 원하는 방법으로 설치하면 CLI가 동작하는 순간 몇 초 안에 알아서 연결돼요
- **로컬 AI 속도**: 이 Mac에서 실행 중인 LM Studio, Ollama, llama.cpp 서버를 찾아 로드된 모델(형식, 양자화, 컨텍스트, 크기)과 생성 속도, 첫 토큰까지 시간, 입력 처리 속도를 보여줘요. **빠른 측정**과 **컨텍스트별 측정**(입력 약 1k / 8k / 32k 토큰)으로 직접 측정할 수 있고, LM Studio는 다른 앱의 요청도 기록해요(속도만 저장하고 대화 내용은 저장하지 않아요). 메모리 압력 경고와 GPU 사용률, 스왑, 시스템 전력도 함께 보여줘요. 메뉴 막대에는 최근 일반 요청의 속도가 나와요(`LLM 16.9`)
- **설정**: 메뉴 막대 항목, 배지에 표시할 서비스(여러 개 가능), 사용량/남은 양 표시, 갱신 주기, IP·계정 이메일 표시, 로그인 시 자동 실행
- **언어**: 한국어와 영어. 기본값은 시스템 언어를 따르고, 설정 → 일반 → 언어에서 바꿀 수 있어요

메뉴 막대 왼쪽 배지는 고정한 서비스별 사용량이에요(위 그림은 Claude · ChatGPT · Gemini, 컬러 로고로 구분). 오른쪽은 CPU · 온도 · 메모리 · SSD · 네트워크 속도예요. 각 카드의 핀 버튼이나 설정에서 서비스를 고정하거나 해제할 수 있어요.

### 설치 (Release)
1. [Releases](https://github.com/ksemperor97/MacDashboard/releases)에서 `MacDashboard-<버전>.zip`을 받아 압축을 풀고 `MacDashboard.app`을 `/Applications`로 옮겨요.
2. 이 앱은 Apple 공증을 받지 않은 ad-hoc 서명이라 처음 열 때 macOS가 막아요. 한 번 열기를 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기"** 버튼을 누르세요. 터미널에서는 이 명령으로도 돼요.
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacDashboard.app
   ```

**요구 사항**: Apple Silicon Mac, macOS 26 (Tahoe) 이상. AI 사용량은 그 Mac에서 로그인된 Claude Code / Codex / Antigravity CLI 계정 기준이에요. 쓰지 않는 서비스는 설정에서 끌 수 있어요. 온도·팬은 M5 Max에서만 확인했어요.

### 소스에서 빌드
```bash
scripts/build_app.sh            # build/MacDashboard.app 생성
scripts/build_app.sh --install  # /Applications 에 설치
scripts/build_app.sh --zip      # 릴리스용 zip 생성
```
Xcode 없이 Command Line Tools(Swift 6.4)만으로 빌드돼요. 서명은 ad-hoc이에요.

### 데이터 출처
| 항목 | 출처 |
|---|---|
| CPU / 메모리 | Mach `host_processor_info`, `host_statistics64`, `sysctl` (`kern.memorystatus_vm_pressure_level`) |
| 디스크 | `volumeAvailableCapacityForImportantUsage` (Finder와 같은 값), IOBlockStorageDriver 통계 |
| 외장 디스크 | DiskArbitration으로 외장 물리 디스크만 고르고 `statfs`로 용량을 읽어요. 네트워크·FUSE 마운트는 제외해요. 30초마다, 그리고 연결/해제 알림이 올 때 다시 확인해요 |
| 네트워크 | `NET_RT_IFLIST2` 64비트 카운터, SystemConfiguration. VPN을 쓸 때는 실제로 트래픽이 지나가는 물리 인터페이스를 보여줘요 |
| GPU | IOAccelerator `PerformanceStatistics` |
| 온도 / 팬 | AppleSMC (`Tp*`, `Tg*`, `F*Ac`), IOHIDEventSystem (root 권한 불필요) |
| Claude | Claude Code가 키체인에 저장한 OAuth 토큰 → `api.anthropic.com/api/oauth/usage` |
| ChatGPT | `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage`. 실패하면 `~/.codex/sessions`의 마지막 기록을 써요 |
| Gemini | `agy -p /quota --output-format json` (Antigravity CLI. 쿼터를 소모하지 않음) |

AI 사용량 API는 공식 문서가 없는 내부 엔드포인트라 바뀔 수 있어요. 토큰은 읽기만 하고, 직접 갱신하거나 다른 곳에 저장하지 않아요.

### 진단용 실행 옵션
```bash
build/MacDashboard.app/Contents/MacOS/MacDashboard --dump-system     # 시스템 수치 3회 출력
build/MacDashboard.app/Contents/MacOS/MacDashboard --dump-usage      # AI 사용량 조회 결과 출력
build/MacDashboard.app/Contents/MacOS/MacDashboard --probe-sensors   # SMC/HID 온도·팬 센서 목록
open build/MacDashboard.app --args --open system|usage|settings     # 실행 직후 해당 창 열기
build/MacDashboard.app/Contents/MacOS/MacDashboard --render-logos out.png  # 서비스 로고를 PNG로 출력
```

앱 아이콘은 `scripts/make_icon.py`(Pillow 필요)로 만들어 `Resources/AppIcon.icns`에 저장해요.

### 출처
서비스 로고의 벡터 경로는 [Lobe Icons](https://github.com/lobehub/lobe-icons)(MIT License)에서 가져왔어요. Claude, ChatGPT/OpenAI, Gemini 로고는 각 소유자의 상표이며, 각 서비스의 사용량을 표시하는 용도로만 써요. 이 프로젝트는 해당 회사들과 관련이 없어요.
