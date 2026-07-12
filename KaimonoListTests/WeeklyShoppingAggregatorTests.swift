import Testing
@testable import KaimonoList

/// WeeklyShoppingAggregator の「1週間分の献立の材料を品名で集約する」処理の検証。
/// 同じ品名を複数レシピにまたいでまとめること、人数に応じて数量をスケールすること、
/// 参照切れのエントリを無視することを確認する。
@MainActor
struct WeeklyShoppingAggregatorTests {

    // MARK: - テスト用の生成ヘルパー

    private func recipe(id: String, name: String, base: Int? = nil,
                        _ ingredients: [(String, String?)]) -> Recipe {
        Recipe(
            id: id,
            name: name,
            emoji: "🍽️",
            ingredients: ingredients.map { RecipeIngredient(name: $0.0, quantity: $0.1) },
            memo: nil,
            baseServings: base,
            createdAt: nil
        )
    }

    private func entry(recipeId: String, servings: Int? = nil) -> MealPlanEntry {
        MealPlanEntry(
            id: "\(recipeId)-entry",
            date: "2026-07-12",
            recipeId: recipeId,
            recipeName: recipeId,
            recipeEmoji: "🍽️",
            addedByUid: "u1",
            servings: servings,
            createdAt: nil,
            ingredientsAddedAt: nil
        )
    }

    private func index(_ recipes: [Recipe]) -> [String: Recipe] {
        Dictionary(uniqueKeysWithValues: recipes.compactMap { r in r.id.map { ($0, r) } })
    }

    // MARK: - 集約

    @Test("同じ品名は複数レシピをまたいで1件にまとめる")
    func mergesSameNameAcrossRecipes() {
        let a = recipe(id: "a", name: "カレー", [("玉ねぎ", "2個"), ("じゃがいも", "3個")])
        let b = recipe(id: "b", name: "肉じゃが", [("玉ねぎ", "1個"), ("牛肉", "200g")])

        let items = WeeklyShoppingAggregator.aggregate(
            entries: [entry(recipeId: "a"), entry(recipeId: "b")],
            recipesById: index([a, b])
        )

        // 玉ねぎ・じゃがいも・牛肉の3品目にまとまる
        #expect(items.count == 3)
        let onion = items.first { $0.name == "玉ねぎ" }
        #expect(onion?.quantities == ["2個", "1個"])
        #expect(onion?.recipeNames == ["カレー", "肉じゃが"])
    }

    @Test("数量は献立の人数に合わせてスケールする")
    func scalesQuantitiesByServings() {
        let a = recipe(id: "a", name: "唐揚げ", base: 2, [("鶏もも肉", "200g")])

        let items = WeeklyShoppingAggregator.aggregate(
            entries: [entry(recipeId: "a", servings: 4)],
            recipesById: index([a])
        )

        #expect(items.first?.quantities == ["400g"])
    }

    @Test("数量が無い材料は内訳を持たない")
    func keepsEmptyQuantitiesWhenUnspecified() {
        let a = recipe(id: "a", name: "サラダ", [("レタス", nil), ("塩", "適量")])

        let items = WeeklyShoppingAggregator.aggregate(
            entries: [entry(recipeId: "a")],
            recipesById: index([a])
        )

        #expect(items.first { $0.name == "レタス" }?.quantities == [])
        #expect(items.first { $0.name == "塩" }?.quantities == ["適量"])
    }

    @Test("同じ表記の数量は重ねない(適量など)")
    func deduplicatesIdenticalQuantities() {
        let a = recipe(id: "a", name: "炒め物", [("塩", "適量")])
        let b = recipe(id: "b", name: "スープ", [("塩", "適量")])

        let items = WeeklyShoppingAggregator.aggregate(
            entries: [entry(recipeId: "a"), entry(recipeId: "b")],
            recipesById: index([a, b])
        )

        let salt = items.first { $0.name == "塩" }
        #expect(salt?.quantities == ["適量"])
        // 由来の料理は重複せず両方残る
        #expect(salt?.recipeNames == ["炒め物", "スープ"])
    }

    @Test("参照先レシピが見つからないエントリは無視する")
    func ignoresEntriesWithMissingRecipe() {
        let a = recipe(id: "a", name: "カレー", [("玉ねぎ", "2個")])

        let items = WeeklyShoppingAggregator.aggregate(
            entries: [entry(recipeId: "a"), entry(recipeId: "zzz")],
            recipesById: index([a])
        )

        #expect(items.count == 1)
        #expect(items.first?.name == "玉ねぎ")
    }

    @Test("エントリが無ければ空を返す")
    func returnsEmptyForNoEntries() {
        #expect(WeeklyShoppingAggregator.aggregate(entries: [], recipesById: [:]).isEmpty)
    }
}
