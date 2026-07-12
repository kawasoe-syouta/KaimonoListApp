import SwiftUI

/// まとめてリストに追加するビュー。今週(今日から7日分)の献立のうち、まだ買い物リストへ
/// 展開していない材料を、レシピごとのセクションで一覧する。
/// レシピ本来の分量(基準人数)を直接編集でき、追加時にその編集内容をレシピ帳へも反映する。
/// 各材料には売り場(カテゴリ)のラベルを添えて表示する。
/// 下部の「まとめてリストに追加」で、チェックした材料を献立の人数にスケールして買い物リストへ追加する。
struct WeeklyShoppingView: View {
    let viewModel: MealPlannerViewModel
    @Environment(\.dismiss) private var dismiss

    /// 画面表示中に編集できるよう、レシピ単位のグループを一度だけローカル状態へ取り込む
    @State private var recipes: [EditableRecipe] = []
    @State private var didLoad = false

    /// チェックの付いた(追加対象の)材料の総数(品名が空の行は数えない)
    private var selectedCount: Int {
        recipes.reduce(0) { total, recipe in
            total + recipe.ingredients.filter { $0.isSelected && !$0.trimmedName.isEmpty }.count
        }
    }

    /// 表示中の材料の総品数(品名が空の行は数えない)
    private var itemCount: Int {
        recipes.reduce(0) { total, recipe in
            total + recipe.ingredients.filter { !$0.trimmedName.isEmpty }.count
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if recipes.isEmpty {
                    ContentUnavailableView(
                        "追加できる材料はありません",
                        systemImage: "cart",
                        description: Text("今週の献立の材料はすべてリストへ追加済みか、まだ献立が登録されていません。")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("まとめてリストに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
        }
        .task {
            // 表示のたびにリセットしないよう初回のみ取り込む
            guard !didLoad else { return }
            recipes = makeEditableRecipes()
            didLoad = true
        }
    }

    private var list: some View {
        List {
            Section {
                LabeledContent("料理", value: "\(recipes.count)品")
                LabeledContent("材料", value: "\(selectedCount)/\(itemCount)品目")
            } header: {
                Text("リストに追加する材料")
            } footer: {
                Text("チェックした材料を追加します。材料名・数量の欄をタップすると書き換えられます。数量はレシピの基準人数の分量です。材料名・数量の編集・削除・追加はレシピにも反映されます。売り場カテゴリはタグから変更でき、この買い物リストにのみ反映されます。")
            }

            ForEach($recipes) { $recipe in
                Section {
                    ForEach($recipe.ingredients) { $ingredient in
                        EditableIngredientRow(
                            ingredient: $ingredient,
                            categories: viewModel.categories,
                            guessCategoryId: { viewModel.categoryId(for: $0) }
                        )
                    }
                    .onDelete { offsets in
                        $recipe.ingredients.wrappedValue.remove(atOffsets: offsets)
                    }

                    Button {
                        $recipe.ingredients.wrappedValue.append(EditableIngredient())
                    } label: {
                        Label("材料を追加", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                } header: {
                    HStack {
                        Text("\(recipe.recipeEmoji) \(recipe.recipeName)")
                        Spacer()
                        Text("基準\(recipe.baseServings)人前")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("同じ品名がすでに未購入リストにある材料は追加されません(数量の合算はしません)。買い物リストへは献立の人数に合わせて数量を調整して追加します。")
            }
        }
    }

    /// 下部固定の一括追加ボタン。追加対象(チェック済み)が1件でもあるときだけ有効にする
    @ViewBuilder
    private var addBar: some View {
        if !recipes.isEmpty {
            Button {
                Task {
                    await apply()
                    dismiss()
                }
            } label: {
                Label("まとめてリストに追加", systemImage: "cart.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0)
            .padding()
            .background(.bar)
        }
    }

    /// ViewModel のレシピグループを、編集可能なローカルモデルへ変換する
    private func makeEditableRecipes() -> [EditableRecipe] {
        viewModel.weeklyRecipeGroups().map { group in
            EditableRecipe(
                recipeId: group.recipeId,
                recipeName: group.recipeName,
                recipeEmoji: group.recipeEmoji,
                baseServings: group.baseServings,
                ingredients: group.ingredients.map { ingredient in
                    EditableIngredient(
                        id: ingredient.id,
                        name: ingredient.name,
                        quantity: ingredient.quantity ?? "",
                        categoryId: viewModel.categoryId(for: ingredient.name)
                    )
                }
            )
        }
    }

    /// 編集内容をレシピ帳へ反映しつつ、チェック済みの材料を買い物リストへ追加する
    private func apply() async {
        let edits = recipes.map { recipe -> MealPlannerViewModel.WeeklyRecipeEdit in
            let ingredients = recipe.ingredients.map { item -> RecipeIngredient in
                let quantity = item.quantity.trimmingCharacters(in: .whitespaces)
                return RecipeIngredient(
                    id: item.id,
                    name: item.name,
                    quantity: quantity.isEmpty ? nil : quantity
                )
            }
            let selected = Set(recipe.ingredients.filter(\.isSelected).map(\.id))
            // 画面で選んだカテゴリ(未選択の材料は含めず、追加時に品名から推定させる)
            var categoryByIngredientId: [String: String] = [:]
            for item in recipe.ingredients {
                if let categoryId = item.categoryId {
                    categoryByIngredientId[item.id] = categoryId
                }
            }
            return MealPlannerViewModel.WeeklyRecipeEdit(
                recipeId: recipe.recipeId,
                ingredients: ingredients,
                selectedIngredientIds: selected,
                categoryByIngredientId: categoryByIngredientId
            )
        }
        await viewModel.applyWeeklyEditsAndAdd(edits)
    }
}

// MARK: - 編集可能なローカルモデル

/// まとめ買い画面で編集できるレシピ1件(基準人数の分量で持つ)
private struct EditableRecipe: Identifiable {
    let recipeId: String
    let recipeName: String
    let recipeEmoji: String
    let baseServings: Int
    var ingredients: [EditableIngredient]
    var id: String { recipeId }
}

/// まとめ買い画面で編集できる材料1件。チェックの有無・品名・数量・売り場カテゴリを変更できる。
/// id は RecipeIngredient.id を引き継ぐ(新規追加行は新しい UUID を採番)。
private struct EditableIngredient: Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var quantity: String = ""
    /// 選んでいる売り場カテゴリのID。nil は未分類。
    var categoryId: String? = nil
    /// まだ手動でカテゴリを選んでいない間だけ true。品名の変更に追従して自動推定する。
    var categoryIsAuto: Bool = true
    var isSelected: Bool = true
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}

// MARK: - 材料の行

/// 材料1件の編集行。チェック・品名(編集可)・売り場カテゴリ(選択可)・数量(編集可)を表示する
private struct EditableIngredientRow: View {
    @Binding var ingredient: EditableIngredient
    let categories: [ItemCategory]
    /// 品名から売り場カテゴリを推定するクロージャ(まだ手動で選んでいない行に使う)
    let guessCategoryId: (String) -> String?

    /// 現在選んでいるカテゴリ(参照切れ・未選択なら nil)
    private var selectedCategory: ItemCategory? {
        guard let id = ingredient.categoryId else { return nil }
        return categories.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                ingredient.isSelected.toggle()
            } label: {
                Image(systemName: ingredient.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ingredient.isSelected ? Color.accentColor : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(ingredient.isSelected ? "追加しない" : "追加する")

            VStack(alignment: .leading, spacing: 6) {
                TextField("材料名", text: $ingredient.name)
                    .foregroundStyle(ingredient.isSelected ? .primary : .secondary)
                    .editableFieldStyle()
                    .onChange(of: ingredient.name) { _, newName in
                        // 手動でカテゴリを選ぶまでは品名から自動推定する
                        if ingredient.categoryIsAuto {
                            ingredient.categoryId = guessCategoryId(newName)
                        }
                    }
                categoryMenu
            }

            Spacer(minLength: 8)

            TextField("数量", text: $ingredient.quantity)
                .multilineTextAlignment(.trailing)
                .font(.subheadline)
                .frame(width: 96)
                .editableFieldStyle()
        }
        .padding(.vertical, 2)
    }

    /// 売り場カテゴリを選ぶメニュー。タップで一覧から変更でき、選ぶと自動推定を止める。
    private var categoryMenu: some View {
        Menu {
            Picker("売り場", selection: categorySelection) {
                Text("未分類").tag(String?.none)
                ForEach(categories) { category in
                    Text("\(category.emoji) \(category.name)").tag(category.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                Text(selectedCategory.map { "\($0.emoji) \($0.name)" } ?? "未分類")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("売り場カテゴリ")
    }

    /// カテゴリ選択のバインディング。手動で選んだら自動推定を止める。
    private var categorySelection: Binding<String?> {
        Binding(
            get: { ingredient.categoryId },
            set: { newValue in
                ingredient.categoryId = newValue
                ingredient.categoryIsAuto = false
            }
        )
    }
}

// MARK: - 入力欄の見た目

private extension View {
    /// タップして書き換えられることが伝わるよう、TextField を淡い背景と枠の「入力欄」に見せる
    func editableFieldStyle() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )
    }
}
