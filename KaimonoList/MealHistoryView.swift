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
    /// レシピ帳のレシピ(createdAt 順)。記録追加シートのレシピ選択に使う
    private(set) var recipes: [Recipe] = []
    /// 初回(または再読み込み)の読み込み中
    private(set) var isLoading = false
    /// 「もっと見る」での追加読み込み中
    private(set) var isLoadingMore = false
    /// さらに古い記録が残っているか(= 直前のページが満杯だったか)
    private(set) var hasMore = true
    /// 初回読み込みを済ませたか(.task の多重実行を防ぐ)
    private(set) var hasLoadedOnce = false
    var errorMessage: String?
    /// 「○/○に記録しました」などの操作フィードバック
    var infoMessage: String?

    /// 1回の取得件数。「もっと見る」でこの件数ずつ古い記録を足す
    static let pageSize = 40

    // MARK: - 依存

    let householdId: String
    let currentUid: String
    let currentUserName: String
    private let db = Firestore.firestore()
    /// 次ページ取得の起点にする、直近ページの最後のドキュメント(カーソル)
    private var lastDocument: DocumentSnapshot?

    private var householdRef: DocumentReference {
        db.collection("households").document(householdId)
    }
    private var recipesRef: CollectionReference { householdRef.collection("recipes") }
    private var plansRef: CollectionReference { householdRef.collection("mealPlans") }

    init(householdId: String, currentUid: String, currentUserName: String) {
        self.householdId = householdId
        self.currentUid = currentUid
        self.currentUserName = currentUserName
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
            let loaded = snapshot.documents.compactMap { try? $0.data(as: Recipe.self) }
            recipes = loaded
            recipesById = Dictionary(
                loaded.compactMap { recipe in recipe.id.map { ($0, recipe) } },
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

    // MARK: - 事後記録(食べたものをあとから記録する)

    /// レシピ帳にまだ無い「定番レシピ」。記録追加シートの「いろいろな料理」欄に使う。
    /// すでに同名レシピを登録済みのものは重複を避けて除外する。
    var catalogCandidates: [Recipe] {
        let registered = Set(recipes.map { MealSuggester.normalize($0.name) })
        return RecipeCatalog.all.filter { !registered.contains(MealSuggester.normalize($0.name)) }
    }

    /// 選んだレシピを指定日の献立(記録)として保存する。
    /// カタログ由来(まだ Firestore に無い)なら先にレシピ帳へ保存してから記録する。
    /// 保存後は一覧を取り直し、記録した日を操作フィードバックとして知らせる。
    func addRecord(recipe: Recipe, on date: Date, servings: Int) async {
        let clamped = MealPlannerViewModel.clampedServings(servings)
        do {
            // 記録に使う recipeId を決める(カタログはレシピ帳へマテリアライズ)
            let recipeId = try await resolvedRecipeId(for: recipe)
            let entry = MealPlanEntry(
                id: nil,
                date: MealPlannerViewModel.dateKey(date),
                recipeId: recipeId,
                recipeName: recipe.name,
                recipeEmoji: recipe.emoji,
                addedByUid: currentUid,
                servings: clamped,
                createdAt: nil,          // サーバー時刻
                ingredientsAddedAt: nil
            )
            _ = try plansRef.addDocument(from: entry)
            // 追加した記録が一覧に出るよう先頭から取り直す
            await reload()
            // 今日の分は「記録(過去)」ではなく献立タブの今日に入るので、その旨を伝える
            infoMessage = Calendar.current.isDateInToday(date)
                ? "今日の献立に追加しました(「献立」タブに表示されます)"
                : "\(Self.recordedDateLabel(for: date))に記録しました"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 記録に使うレシピの Firestore ドキュメントIDを返す。
    /// レシピ帳のレシピはそのID、カタログ由来は同名があれば再利用し、無ければ保存して採番する。
    private func resolvedRecipeId(for recipe: Recipe) async throws -> String {
        guard RecipeCatalog.isCatalog(recipe) else {
            if let id = recipe.id { return id }
            throw NSError(domain: "MealHistory", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "レシピを特定できませんでした"])
        }
        let key = MealSuggester.normalize(recipe.name)
        if let existing = recipes.first(where: { MealSuggester.normalize($0.name) == key }),
           let id = existing.id {
            return id
        }
        // id / createdAt はサーバー採番に任せるため、合成値を外した新規レシピを保存する
        let newRecipe = Recipe(
            id: nil,
            name: recipe.name,
            emoji: recipe.emoji,
            ingredients: recipe.ingredients,
            memo: recipe.memo,
            createdAt: nil
        )
        let ref = try recipesRef.addDocument(from: newRecipe)
        return ref.documentID
    }

    /// 記録完了メッセージ用の日付ラベル("今日" / "昨日" / "M/d(E)")
    private static func recordedDateLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今日" }
        if calendar.isDateInYesterday(date) { return "昨日" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E)"
        return formatter.string(from: date)
    }
}

// MARK: - 食べた記録の画面

/// 過去の献立(食べたもの)を新しい順に振り返る画面。日付ごとにまとめて表示し、
/// タップで材料を確認できる。読み取り専用で、献立の追加・削除は行わない。
struct MealHistoryView: View {
    @State private var viewModel: MealHistoryViewModel
    /// 材料確認シートの対象。nil = 非表示
    @State private var detailTarget: MealPlanEntry?
    /// 記録追加シートの表示状態
    @State private var isAddingRecord = false

    init(householdId: String, currentUid: String, currentUserName: String) {
        _viewModel = State(initialValue: MealHistoryViewModel(
            householdId: householdId,
            currentUid: currentUid,
            currentUserName: currentUserName
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.entries.isEmpty {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView {
                            Label("まだ記録がありません", systemImage: "clock.arrow.circlepath")
                        } description: {
                            Text("献立に入れた料理は、日付が過ぎるとここで振り返れます。食べたものをあとから記録することもできます。")
                        } actions: {
                            Button("記録する") { isAddingRecord = true }
                        }
                    }
                } else {
                    historyList
                }
            }
            .navigationTitle("食べた記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingRecord = true
                    } label: {
                        Label("記録する", systemImage: "plus")
                    }
                    .accessibilityLabel("食べたものを記録する")
                }
            }
            .task { await viewModel.loadInitial() }
            .refreshable { await viewModel.reload() }
            .sheet(isPresented: $isAddingRecord) {
                RecordAddSheet(viewModel: viewModel)
                    .presentationDetents([.large])
            }
            .sheet(item: $detailTarget) { entry in
                MealHistoryDetailSheet(viewModel: viewModel, entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .alert("エラー", isPresented: errorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("記録", isPresented: infoBinding) {
                Button("OK") { viewModel.infoMessage = nil }
            } message: {
                Text(viewModel.infoMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var infoBinding: Binding<Bool> {
        Binding(
            get: { viewModel.infoMessage != nil },
            set: { if !$0 { viewModel.infoMessage = nil } }
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

// MARK: - 記録追加シート(食べたものをあとから記録する)

/// 食べたものをあとから記録するシート。まず「いつ食べたか」を今日/昨日/一昨日の
/// クイックチップ(またはそれ以前の日付を DatePicker)で選び、次にレシピを選ぶと
/// その日の記録として保存する。事後記録は今日・昨日が大半なので最短で選べるようにする。
private struct RecordAddSheet: View {
    let viewModel: MealHistoryViewModel

    @Environment(\.dismiss) private var dismiss
    /// 記録する日(既定は今日)
    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    /// 記録する人数
    @State private var servings = MealPlanEntry.defaultServings
    @State private var searchText = ""

    /// レシピ帳のレシピ(検索で絞り込み)
    private var myRecipes: [Recipe] { filtered(viewModel.recipes) }
    /// アプリ内蔵の定番レシピ(登録済みの同名は除外・検索で絞り込み)
    private var catalog: [Recipe] { filtered(viewModel.catalogCandidates) }
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    quickDateChips
                    DatePicker("それ以前の日", selection: $selectedDate,
                               in: ...Calendar.current.startOfDay(for: Date()),
                               displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                } header: {
                    Text("いつ食べた？")
                } footer: {
                    Text("食べた日を選んでからレシピを選ぶと、その日に記録します。")
                }

                Section {
                    Stepper(value: $servings, in: MealPlannerViewModel.servingsRange) {
                        HStack {
                            Text("人数")
                            Spacer()
                            Text("\(servings)人前")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("選んだレシピをこの人数で記録します。")
                }

                if !myRecipes.isEmpty {
                    Section("マイレシピ") {
                        ForEach(myRecipes) { recipe in
                            recipeButton(recipe, subtitle: "材料 \(recipe.ingredients.count)品")
                        }
                    }
                }

                if !catalog.isEmpty {
                    Section {
                        ForEach(catalog) { recipe in
                            recipeButton(recipe, subtitle: ingredientSummary(recipe))
                        }
                    } header: {
                        Text("いろいろな料理から選ぶ")
                    } footer: {
                        Text("選ぶと自動でマイレシピに登録されます。")
                    }
                }

                if isSearching && myRecipes.isEmpty && catalog.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .searchable(text: $searchText, prompt: "料理名・食材で検索")
            .navigationTitle("食べたものを記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    /// 今日・昨日・一昨日のクイック日付チップ。タップでその日を選ぶ
    private var quickDateChips: some View {
        HStack(spacing: 8) {
            ForEach(Self.quickDates, id: \.label) { item in
                let isSelected = Calendar.current.isDate(selectedDate, inSameDayAs: item.date)
                Button {
                    selectedDate = item.date
                } label: {
                    Text(item.label)
                        .font(.subheadline)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground),
                                    in: Capsule())
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
    }

    /// クイックチップの候補(今日・昨日・一昨日)
    private static var quickDates: [(label: String, date: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return [
            ("今日", today),
            ("昨日", calendar.date(byAdding: .day, value: -1, to: today) ?? today),
            ("一昨日", calendar.date(byAdding: .day, value: -2, to: today) ?? today),
        ]
    }

    /// レシピ1件のボタン行。選ぶと記録して閉じる
    @ViewBuilder
    private func recipeButton(_ recipe: Recipe, subtitle: String) -> some View {
        Button {
            Task { await viewModel.addRecord(recipe: recipe, on: selectedDate, servings: servings) }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(recipe.emoji)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .foregroundStyle(.primary)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// 料理名または材料名で絞り込む(検索語が空ならそのまま返す)
    private func filtered(_ recipes: [Recipe]) -> [Recipe] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recipes }
        return recipes.filter { recipe in
            recipe.name.localizedCaseInsensitiveContains(query)
                || recipe.ingredients.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    /// 定番レシピの補足行(主な材料を先頭3件まで)
    private func ingredientSummary(_ recipe: Recipe) -> String {
        let names = recipe.ingredients.prefix(3).map(\.name).joined(separator: "・")
        return recipe.ingredients.count > 3 ? "\(names) ほか" : names
    }
}
