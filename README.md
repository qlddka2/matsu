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
- 구글 로그인 + 공유 PvE 랭킹(Supabase). 로그인하지 않으면 기록은 이 기기에만 저장됩니다.

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

## Supabase 설정 (로그인·공유 랭킹)
1. Supabase 대시보드 → **SQL Editor → New query** 에 `supabase/schema.sql` 전체를 붙여넣고 **Run**.
   (프로필·랭킹 테이블, 접근 규칙, 닉네임/결과 제출 함수가 만들어집니다. 여러 번 실행해도 안전합니다.)
2. **Authentication → Sign In / Providers → Google** 켜기(Google Cloud에서 만든 클라이언트 ID/보안 비밀번호 입력).
3. **Authentication → URL Configuration** 의 Site URL 과 Redirect URLs 에 배포 주소(`https://<계정>.github.io/<저장소>/`)를 추가.
4. 프로젝트 주소와 공개 키는 `config.js` 에 들어 있습니다. 공개용 값이라 저장소에 올려도 되지만 **service_role 키는 절대 넣지 마세요.**

### 랭크 대전(PvP) 켜기
5. 위 1번 다음에 `supabase/pvp.sql` 전체를 SQL Editor에서 같은 방식으로 **Run** (여러 번 실행해도 안전).
6. 서로 다른 구글 계정 두 개(브라우저 두 개 또는 시크릿 창)로 로그인해 동시에 **랭크 대전 찾기**를 눌러 확인합니다.

랭킹 점수(RP)는 `submit_challenge` 함수가 서버에서 계산하고, 테이블에는 앱이 직접 쓸 수 없습니다.
한 판의 점수는 아직 기기에서 계산되므로 완전한 부정 방지는 PvP 단계(서버 판정)에서 이뤄집니다.

## 업데이트할 때
- `index.html`을 수정하고 push 합니다.
- 오프라인 캐시를 새로 받게 하려면 `sw.js`의 `VERSION` 값을 올립니다.

## 구조
```
index.html              게임 전체(HTML·CSS·JS 한 파일)
config.js               Supabase 주소·공개 키
supabase/schema.sql     DB 테이블·규칙·함수(SQL Editor에 붙여넣기)
supabase/pvp.sql        랭크 대전(매칭·판정·MMR) — schema.sql 다음에 실행
manifest.webmanifest    설치형 웹앱 설정
sw.js                   오프라인 캐시
icons/                  아이콘
.github/workflows/      GitHub Pages 자동 배포
```

## 다음 계획
- 카카오·네이버 로그인
- 앱 배포: Capacitor로 안드로이드/iOS 래핑
