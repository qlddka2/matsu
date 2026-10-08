# 맞수 (가제)

같은 카드 9장을 두 사람이 한 장씩 동시에 내는 1:1 카드 대결 게임. 별도 빌드 없이 `index.html` 하나로 동작하는 정적 웹앱(PWA)입니다.

## 규칙 요약
- 숫자 1~9 카드 9장을 똑같이 받고, 매 라운드 공개된 보상 점수를 두고 카드를 동시에 냅니다.
- 숫자가 큰 쪽이 보상을 가져가고, 같으면 보상이 다음 라운드로 이월됩니다.
- 상성(불 > 풀 > 물 > 불)이 유리하면 숫자 +3.
- 스킬 3종(배수·방벽·회수)은 한 판에 각각 한 번.
- 9라운드 후 점수 > 라운드 승수 순으로 승부.

## 기능
- AI 대전(쉬움·보통·어려움), 랭킹 도전(5판, RP·티어), 밸런스 시뮬레이터, 룰 설정
- 효과음·BGM(코드로 합성, 에셋 없음), 기권, 오프라인 실행(PWA)
- 랭킹 기록은 현재 기기(localStorage)에만 저장됩니다.

## 로컬에서 실행
```bash
python3 -m http.server 8000
# http://localhost:8000
```
`index.html`을 바로 열어도 되지만, 설치형(PWA)·오프라인 기능은 http(s) 주소에서만 켜집니다.

## GitHub Pages 배포
1. GitHub에서 새 저장소를 만들고 이 폴더의 파일을 push 합니다.
2. 저장소 **Settings → Pages → Build and deployment → Source** 를 **GitHub Actions** 로 선택합니다.
3. `main`에 push 할 때마다 자동 배포됩니다. 주소는 `https://<계정>.github.io/<저장소>/` 입니다.

## 업데이트할 때
- `index.html`을 수정하고 push 합니다.
- 오프라인 캐시를 새로 받게 하려면 `sw.js`의 `VERSION` 값을 올립니다.

## 구조
```
index.html              게임 전체(HTML·CSS·JS 한 파일)
manifest.webmanifest    설치형 웹앱 설정
sw.js                   오프라인 캐시
icons/                  아이콘
.github/workflows/      GitHub Pages 자동 배포
```

## 다음 계획
- Supabase 연동: 공유 랭킹, 로그인(구글·카카오·네이버), 서버 검증, PvP·MMR
- 앱 배포: Capacitor로 안드로이드/iOS 래핑
