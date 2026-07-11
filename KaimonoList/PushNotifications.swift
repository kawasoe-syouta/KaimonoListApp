import SwiftUI
import UIKit
import UserNotifications
import FirebaseMessaging
import FirebaseFirestore

/// リモート通知(APNs / FCM)まわりの窓口。
/// - APNs トークンの受け取りと FCM への引き渡し(AppDelegate 経由)
/// - FCM 登録トークンの取得と Firestore への保存(世帯メンバーへの送信先になる)
/// - フォアグラウンド時のバナー表示
///
/// 「メンバーが買い物リストに追加したら他メンバーへ通知」は、items サブコレクションの
/// onCreate を監視する Cloud Functions(functions/index.js)から送信する。本クラスは
/// その送信先となるデバイストークンを `households/{id}/deviceTokens/{token}` に登録する。
///
/// スレッド安全性: 状態の読み書きとトークン保存はすべてメインスレッドで行う。
/// Messaging / UNUserNotificationCenter のデリゲートは任意スレッドで呼ばれるため、
/// メインへホップしてから状態に触れる。
@MainActor
final class PushManager: NSObject {

    static let shared = PushManager()

    /// Firestore はテスト環境(Firebase 未構成)でクラッシュしないよう遅延生成する。
    private lazy var db = Firestore.firestore()

    /// 直近に受け取った FCM 登録トークン(未取得なら nil)
    private var latestToken: String?

    /// 現在サインイン中の世帯・ユーザー。両方揃うとトークンを保存できる
    private var context: (householdId: String, uid: String)?

    private override init() { super.init() }

    // MARK: - 起動時セットアップ(AppDelegate から呼ぶ)

    /// デリゲートを接続する。Firebase 構成後(FirebaseApp.configure 済み)に呼ぶこと。
    func configureDelegates() {
        UNUserNotificationCenter.current().delegate = self
        Messaging.messaging().delegate = self
    }

    // MARK: - 通知許可とリモート登録

    /// 通知の許可を求め、許可されたら APNs へ登録する。
    /// サインイン完了後に呼ぶ(未サインインのユーザーには尋ねない)。
    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { granted, _ in
            guard granted else { return }
            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    // MARK: - セッションとの連携(SessionStore から呼ぶ)

    /// サインイン中の世帯・ユーザーを設定し、トークンが取れていれば保存する。
    func updateContext(householdId: String, uid: String) {
        context = (householdId, uid)
        saveTokenIfPossible()
    }

    /// サインアウト・世帯退出時に、この世帯のトークン登録を削除する。
    /// (退出で memberIds から外れるとルール上書き込めなくなるため、外れる前に呼ぶこと)
    func clearRegistration() async {
        guard let context, let token = latestToken else { self.context = nil; return }
        try? await db.collection("households")
            .document(context.householdId)
            .collection("deviceTokens")
            .document(token)
            .delete()
        self.context = nil
    }

    // MARK: - トークン保存

    private func saveTokenIfPossible() {
        guard let context, let token = latestToken else { return }
        db.collection("households")
            .document(context.householdId)
            .collection("deviceTokens")
            .document(token)
            .setData([
                "uid": context.uid,
                "updatedAt": FieldValue.serverTimestamp(),
            ], merge: true)
    }
}

// MARK: - MessagingDelegate

extension PushManager: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging,
                               didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in
            self.latestToken = fcmToken
            self.saveTokenIfPossible()
        }
        #if DEBUG
        // 動作確認用: FCM コンソールの「テスト送信」に貼り付けるためコンソールへ出力する。
        print("📲 FCM registration token: \(fcmToken ?? "nil")")
        #endif
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushManager: UNUserNotificationCenterDelegate {
    /// アプリを開いている間に届いた通知も、バナーと音で知らせる。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

// MARK: - AppDelegate(SwiftUI ライフサイクルに接続)

/// SwiftUI アプリに UIApplicationDelegate を橋渡しする。
/// APNs デバイストークンの受け渡しは AppDelegate でしか受け取れないため必要。
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // テスト時は Firebase 未構成のため Messaging に触れない(本番フローは不変)。
        if !AppEnvironment.isRunningUnitTests {
            PushManager.shared.configureDelegates()
        }
        return true
    }

    /// APNs デバイストークンを受け取り、FCM へ引き渡す。
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 登録失敗(シミュレータや権限拒否など)。致命的ではないのでログのみ。
        print("リモート通知の登録に失敗: \(error.localizedDescription)")
    }
}
