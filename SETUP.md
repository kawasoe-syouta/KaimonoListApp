# 買い物リストと献立 セットアップ手順

家族で共有する買い物リスト + 献立プランナー(リアルタイム同期 / Sign in with Apple / プッシュ通知)。

## 前提
- Mac + Xcode 16 以降
- デプロイターゲット: **iOS 17.0 以上**(`@Observable` を使用)
- **Apple Developer Program($99/年)が必要**。Sign in with Apple / プッシュ通知の Capability、実機ビルド、App Store 提出に必須。
- Firebase プロジェクト(Firestore + Auth + Cloud Messaging)。プッシュ通知の Functions を使う場合は **Blaze プラン**が必要。

## 1. プロジェクトを開く
1. リポジトリを clone し、`KaimonoList.xcodeproj` を Xcode で開く
2. Bundle Identifier は `com.kawasoe.KaimonoList`(Firebase 登録で使用。自分用に変える場合は
   Signing & Capabilities で変更し、Firebase 登録の Bundle ID も合わせる)
3. Firebase SDK(`FirebaseAuth` / `FirebaseFirestore` / `FirebaseMessaging`)は Swift Package Manager で
   **統合済み**。初回オープン時に自動でパッケージ解決が走ります(ネットワーク必要)
4. プロジェクトは **Xcode 16 の同期フォルダ**(`PBXFileSystemSynchronizedRootGroup`)構成。
   `KaimonoList/` フォルダに置いたファイルは自動でターゲットに含まれます(pbxproj の個別参照は不要)

## 2. Firebase プロジェクト作成
1. https://console.firebase.google.com → プロジェクトを追加
2. 「iOS アプリを追加」→ 手順1の Bundle ID を入力
3. **GoogleService-Info.plist** をダウンロードし、`KaimonoList/` フォルダに置く
   (同期フォルダ構成なので、フォルダに入れれば自動でターゲットへ含まれる。`.gitignore` 済み)
   - ※未配置だと起動時に `FirebaseApp.configure()` でクラッシュします

## 3. Firebase コンソール側の設定
### Authentication(Sign in with Apple)
- Build → Authentication → Sign-in method → **Apple** を有効化
- iOS ネイティブのサインインだけなら追加入力は不要ですが、**アカウント削除(退会)で
  `revokeToken` を使う**ため、Apple プロバイダの OAuth 設定を入力しておく:
  - Services ID(例 `com.kawasoe.KaimonoList.service`。Apple Developer ポータルで作成し、
    Primary App ID = Bundle ID、Return URL = `https://<project>.firebaseapp.com/__/auth/handler`)
  - Apple Team ID / Key ID / Sign in with Apple 用 `.p8` 秘密鍵
  - ※`.p8` 秘密鍵は機密。漏洩時は Apple Keys で失効 → 再作成 → Firebase に貼り直し

### Firestore
- Build → Firestore Database → データベースを作成
- ロケーション: **asia-northeast1(東京)**、本番環境モード
- CLI で `firestore.rules` をデプロイ(下記「6. Firestore ルールのデプロイ」)

### Cloud Messaging(プッシュ通知)
- プロジェクト設定 → Cloud Messaging → Apple アプリの設定に、**APNs 認証キー(.p8)** を登録
  (Key ID / Team ID とセット)。開発用 `.p8` は dev/prod 兼用のため本番用の追加登録は不要

## 4. Xcode の署名と Capability
1. TARGETS → KaimonoList → Signing & Capabilities でチーム(有料)を選択(自動署名)
2. Capability を追加:
   - **Sign in with Apple**(entitlements に `com.apple.developer.applesignin` = `["Default"]`)
   - **Push Notifications**
   - **Background Modes** → Remote notifications
3. ※Capability の追加はビルド設定の変更なので Xcode UI で行う(コマンドラインからは変更しない)

## 5. ソースファイルの構成
ソースは `KaimonoList/` フォルダに配置済み(clone すればそのまま揃っています):

```
KaimonoList/
├── KaimonoListApp.swift       ← @main。Firebase 構成 → SignInView / RootTabView を出し分け
├── SignInView.swift           ← サインインゲート(SignInWithAppleButton)
├── SessionStore.swift         ← Sign in with Apple + 世帯の用意/参加/退出 + アカウント削除
├── Models.swift               ← データモデル・カテゴリ推定・献立提案・旬食材・定番レシピ・数量スケール
├── RootTabView.swift          ← リスト / 献立 / 共有 タブ + 初回オンボーディング表示
├── OnboardingView.swift       ← 初回起動チュートリアル(4ページ)
├── ShoppingListViewModel.swift / ShoppingListView.swift   ← 買い物リスト + 購入履歴記録
├── CategoryManageView.swift   ← カテゴリの追加・編集・並び替え
├── MealPlannerViewModel.swift / MealPlanView.swift / RecipeListView.swift  ← 献立・レシピ・おすすめ
├── HouseholdViewModel.swift / HouseholdView.swift         ← 共有・メンバー・アカウント設定・退会
├── PushNotifications.swift    ← FCM/APNs 連携(PushManager / AppDelegate)
└── PrivacyInfo.xcprivacy      ← プライバシーマニフェスト
```

## 6. Firestore ルールのデプロイ
`firebase.json` / `.firebaserc`(default プロジェクト)をコミット済み。

```sh
firebase deploy --only firestore:rules
```

ルールの方針は「世帯メンバーだけがその世帯のデータを読み書きできる」。招待コードでの自己参加、
`inviteCodes` の総当たり探索防止、`deviceTokens`(通知送信先)のメンバー限定書き込みを含む。

## 7. Cloud Functions のデプロイ(プッシュ通知)
`functions/index.js` の `notifyItemAdded`(2nd Gen / Node.js / asia-northeast1)が、
`households/{id}/items/{itemId}` の onCreate を検知し、その世帯の `deviceTokens` を列挙して
追加した本人以外へ通知を送る(無効トークンは自動削除)。

```sh
cd functions && npm install
firebase deploy --only functions
```

- 事前に **Blaze プラン**へのアップグレードが必要
- 初回デプロイが `iam.serviceAccounts.ActAs denied` で失敗する場合は API 有効化直後の権限伝播待ち。
  少し待って再実行すると成功する
- メンテ課題: `functions/package.json` の Node.js ランタイム更新(古いバージョンは廃止予定)

## 8. 動作確認チェックリスト
### 認証・世帯
1. 起動 → サインイン画面。Apple でサインインするとメイン画面へ(初回はオンボーディング表示)
2. 別端末・再インストール後も、同じ Apple ID なら同じ世帯データに復帰する
3. 「共有」タブ → アカウント設定から退会 → 再認証 → サインイン画面へ戻る

### 買い物リスト・カテゴリ
1. 「+」からアイテム追加。「にんじん」→ カテゴリが自動で「野菜・果物」になる
2. タップでチェック → 「購入済み」→ まとめて削除(このとき購入履歴に記録される)
3. タグアイコン → カテゴリ画面で追加・編集・並び替え → リストのセクション順に反映される

### 献立・おすすめ
1. 献立タブ → 本アイコン → レシピ帳で登録、または内蔵の定番レシピカタログから選ぶ
2. 日付の「+」でレシピを割り当て、人数を指定 → カートアイコンで材料を買い物リストへ展開
   (人数に応じて分量がスケールされる。未購入リストにある品は重複追加されない)
3. レシピ選択シートの「おすすめ」に、購入履歴・旬の食材・マンネリ回避を反映した提案が理由付きで出る

### 共有・通知
1. 端末A の招待コードを端末B に入力 → 参加 → リストが即時同期される
2. 端末A でアイテムを追加すると端末B にプッシュ通知が届く(バックグラウンドで確認しやすい)
3. 「この世帯から出る」で自分専用の空リストに戻る。メンバー一覧から消える

## 将来課題
- 購入履歴の肥大化対策(古い履歴の整理)
- Cloud Functions の Node.js ランタイム更新
- 世帯オーナー権限・メンバー管理(現状はメンバー相互信頼モデル)
- 通知文言の拡張(カテゴリ別・まとめ通知・献立追加通知など)
