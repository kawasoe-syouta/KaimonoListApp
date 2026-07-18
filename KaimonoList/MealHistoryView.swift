import SwiftUI
import Observation
import FirebaseFirestore

/// 食べた記録(献立の振り返り)の状態管理。
/// 献立プランナー(MealPlannerViewModel)が今日以降＋直近しか保持しないのに対し、
/// こちらは「日付が過ぎた過去の献立」を新しい順にページ取得して振り返れるようにする。
/// 読み取り専用(記録の閲覧のみ)なので、リアルタイム監視はせず都度取得する。
@MainActor
@Observable
final class MealHistoryViewModel {

    // MARK: - 状態

    /// 取得済みの過去の献立(date 降順)。「もっと見る」で古い分を末尾に足していく
    private(set) var entries: [MealPlanEntry] = []
    /// 材料確認用のレシピ表(recipeId → Recipe)。初回に一度だけ取得する
    private(set) var recipesById: [String: Recipe] = [:]
    /// 初回(または再読み込み)の読み込み中
    private(set) var isLoading = false
    /// 「もっと見る」での追加読み込み中
    private(set) var isLoadingMore = false
    /// さらに古い記録が残っているか(= 直前のページが満杯だったか)
    private(set) var hasMore = true
    /// 初回読み込みを済ませたか(.task の多重実行を防ぐ)
    private(set) var hasLoadedOnce = false
    var errorMessage: String?

    /// 1回の取得件数。「もっと見る」でこの件数ずつ古い記録を足す
    static let pageSize = 40

    // MARK: - 依存

    let householdId: String
    private let db = Firestore.firestore()
    /// 次ページ取得の起点にする、直近ページの最後のドキュメント(カーソル)
    private var lastDocument: DocumentSnapshot?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var recipesRef: CollectionReference { householdRef.collection("recipes") }
    private var plansRef: CollectionReference { householdRef.collection("mealPlans") }

    init(householdId: String) {
        self.householdId = householdId
    }

    // MARK: - 読み込み

    /// 初回表示時に一度だけ呼ぶ。レシピ表と履歴の最初のページを読み込む。
    func loadInitial() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await loadRecipes()
        await loadNextPage(reset: true)
    }

    /// 引き下げ更新。レシピ表と履歴を先頭から取り直す。
    func reload() async {
        await loadRecipes()
        await loadNextPage(reset: true)
    }

    /// 材料確認に使うレシピ表を取得する。失敗しても致命的ではない(材料が見られないだけ)。
    private func loadRecipes() async {
        do {
            let snapshot = try await recipesRef.order(by: "createdAt").getDocuments()
            let recipes = snapshot.documents.compactMap { try? $0.data(as: Recipe.self) }
            recipesById = Dictionary(
                recipes.compactMap { recipe in recipe.id.map { ($0, recipe) } },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            // 退出・世帯切り替え時の権限エラーは自然に起きるので警告しない
            if !error.isFirestorePermissionDenied {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 過去の献立(今日より前)を新しい順に1ページ取得する。
    /// - Parameter reset: true なら先頭から取り直す(カーソルを捨てる)。false は続きを追加取得する。
    /// `date` 単一フィールドの範囲＋並び替えなので複合インデックスは不要。
    func loadNextPage(reset: Bool = false) async {
        if reset {
            isLoading = true
            lastDocument = nil
            hasMore = true
        } else {
            guard hasMore, !isLoadingMore, !isLoading else { return }
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }

        let todayKey = MealPlannerViewModel.dateKey(Calendar.current.startOfDay(for: Date()))
        var query: Query = plansRef
            .whereField("date", isLessThan: todayKey)
            .order(by: "date", descending: true)
            .limit(to: Self.pageSize)
        if let lastDocument, !reset {
            query = query.start(afterDocument: lastDocument)
        }

        do {
            let snapshot = try await query.getDocuments()
            let page = snapshot.documents.compactMap { try? $0.data(as: MealPlanEntry.self) }
            if reset {
                entries = page
            } else {
                entries += page
            }
            lastDocument = snapshot.documents.last
            // ページが満杯なら、まだ続きがある可能性がある
            hasMore = snapshot.documents.count == Self.pageSize
        } catch {
            if !error.isFirestorePermissionDenied {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 履歴エントリに対応するレシピ。削除済みなら nil(材料確認シートで使用)
    func recipe(for entry: MealPlanEntry) -> Recipe? {
        recipesById[entry.recipeId]
    }
}

// MARK: - 食べた記録の画面

/// 過去の献立(食べたもの)を新しい順に振り返る画面。日付ごとにまとめて表示し、
/// タップで材料を確認できる。読み取り専用で、献立の追加・削除は行わない。
struct MealHistoryView: View {
    @State private var viewModel: MealHistoryViewModel
    /// 材料確認シートの対象。nil = 非表示
    @State private var detailTarget: MealPlanEntry?

    init(householdId: String) {
        _viewModel = State(initialValue: MealHistoryViewModel(householdId: householdId))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.entries.isEmpty {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView(
                            "まだ記録がありません",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("献立に入れた料理は、日付が過ぎるとここで振り返れます。")
                        )
                    }
                } else {
                    historyList
                }
            }
            .navigationTitle("食べた記録")
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.loadInitial() }
            .refreshable { await viewModel.reload() }
            .sheet(item: $detailTarget) { entry in
                MealHistoryDetailSheet(viewModel: viewModel, entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var historyList: some View {
        List {
            ForEach(groupedByDate, id: \.key) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HistoryRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture { detailTarget = entry }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("材料を確認")
                    }
                } header: {
                    Text(Self.sectionTitle(for: group.key))
                }
            }

            if viewModel.hasMore {
                Section {
                    Button {
                        Task { await viewModel.loadNextPage() }
                    } label: {
                        if viewModel.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("もっと見る")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.isLoadingMore)
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    /// date 降順で取得済みのエントリを、連続する同一日ごとにまとめる。
    /// (取得順がすでに日付降順なので、隣り合う同じ日をひとまとめにするだけでよい)
    private var groupedByDate: [(key: String, entries: [MealPlanEntry])] {
        var groups: [(key: String, entries: [MealPlanEntry])] = []
        for entry in viewModel.entries {
            if groups.last?.key == entry.date {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((key: entry.date, entries: [entry]))
            }
        }
        return groups
    }

    // MARK: - 日付見出し

    /// セクション見出し("yyyy-MM-dd" キー → 「昨日 M/d(E)」/「M/d(E)」/古い年は「yyyy/M/d(E)」)
    private static func sectionTitle(for key: String) -> String {
        guard let date = MealPlannerViewModel.date(fromKey: key) else { return key }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) {
            return "昨日 \(dayFormatter.string(from: date))"
        }
        // 今年と違う年は年も添える(何年前の記録か分かるように)
        let isSameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return (isSameYear ? dayFormatter : dayWithYearFormatter).string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy/M/d(E)"
        return formatter
    }()
}

// MARK: - 記録の行

/// 食べた記録1件の行。料理の絵文字・名前・人数を表示する(日付はセクション見出し側)。
private struct HistoryRow: View {
    let entry: MealPlanEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.recipeEmoji)
                .font(.title3)
            Text(entry.recipeName)
            Spacer()
            Label("\(entry.servingsOrDefault)人前", systemImage: "person.2.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 記録の材料確認シート

/// 過去の献立に入れた料理の材料を確認する読み取り専用シート。
/// 数量は買い物リストへ展開したときと同じ比率(レシピの基準人数 → 献立の人数)でスケールする。
/// レシピが削除済みのときは確認できない旨を表示する。
private struct MealHistoryDetailSheet: View {
    let viewModel: MealHistoryViewModel
    let entry: MealPlanEntry

    @Environment(\.dismiss) private var dismiss

    private var recipe: Recipe? { viewModel.recipe(for: entry) }

    var body: some View {
        NavigationStack {
            Group {
                if let recipe {
                    ingredientsList(for: recipe)
                } else {
                    ContentUnavailableView(
                        "レシピが見つかりません",
                        systemImage: "book.closed",
                        description: Text("このレシピは削除されたため、材料を表示できません。")
                    )
                }
            }
            .navigationTitle("\(recipe?.emoji ?? entry.recipeEmoji) \(recipe?.name ?? entry.recipeName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func ingredientsList(for recipe: Recipe) -> some View {
        List {
            Section {
                if recipe.ingredients.isEmpty {
                    Text("材料が登録されていません")
                        .foregroundStyle(.secondary)
                }
                ForEach(recipe.ingredients) { ingredient in
                    HStack {
                        Text(ingredient.name)
                        Spacer()
                        if let quantity = scaledQuantity(ingredient, in: recipe) {
                            Text(quantity)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("\(entry.servingsOrDefault)人前の材料")
            } footer: {
                if recipe.baseServingsOrDefault != entry.servingsOrDefault {
                    Text("数量はレシピの基準(\(recipe.baseServingsOrDefault)人前)から\(entry.servingsOrDefault)人前に合わせて調整して表示しています。")
                }
            }

            if let memo = recipe.memo, !memo.isEmpty {
                Section("メモ") {
                    Text(memo)
                }
            }
        }
    }

    /// 材料の数量を献立の人数に合わせてスケールする(買い物リストへの展開時と同じ計算)
    private func scaledQuantity(_ ingredient: RecipeIngredient, in recipe: Recipe) -> String? {
        IngredientScaler.scale(ingredient.quantity,
                               from: recipe.baseServingsOrDefault,
                               to: entry.servingsOrDefault)
    }
}
