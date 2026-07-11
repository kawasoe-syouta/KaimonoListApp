import Testing
@testable import KaimonoList

/// MealPlanIngredientRemoval の「献立削除時に買い物リストから消す材料」判定の検証。
/// 他の残る献立で使う材料は残し、その献立だけが使う材料を削除対象にすることを確認する。
@MainActor
struct MealPlanRemovalTests {

    // MARK: - テスト用の生成ヘルパー

    private func recipe(id: String, name: String, ingredients: [String]) -> Recipe {
        Recipe(
            id: id,
            name: name,
            emoji: "🍽️",
            ingredients: ingredients.map { RecipeIngredient(name: $0, quantity: nil) },
            memo: nil,
            createdAt: nil
        )
    }

    private func entry(id: String, recipeId: String) -> MealPlanEntry {
        MealPlanEntry(
            id: id,
            date: "2026-07-12",
            recipeId: recipeId,
            recipeName: recipeId,
            recipeEmoji: "🍽️",
            addedByUid: "u1",
            createdAt: nil,
            ingredientsAddedAt: nil
        )
    }

    private func index(_ recipes: [Recipe]) -> [String: Recipe] {
        Dictionary(uniqueKeysWithValues: recipes.compactMap { r in r.id.map { ($0, r) } })
    }

    // MARK: - 基本ケース

    @Test("他に献立が無ければ全材料が削除対象になる")
    func removesAllWhenNoOtherEntries() {
        let deleted = recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉", "玉ねぎ"])

        let result = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: deleted,
            remainingEntries: [],
            recipesById: index([deleted])
        )

        #expect(result == ["じゃがいも", "牛肉", "玉ねぎ"])
    }

    @Test("他の献立でも使う材料は残す(削除対象から除外)")
    func keepsIngredientsUsedByOtherEntries() {
        let deleted = recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉", "玉ねぎ"])
        let other = recipe(id: "b", name: "カレー", ingredients: ["じゃがいも", "玉ねぎ", "カレールー"])

        let result = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: deleted,
            remainingEntries: [entry(id: "e2", recipeId: "b")],
            recipesById: index([deleted, other])
        )

        // じゃがいも・玉ねぎはカレーでも使うので残り、牛肉だけ削除
        #expect(result == ["牛肉"])
    }

    @Test("すべての材料が他の献立と重なるなら削除対象は空")
    func removesNothingWhenFullyShared() {
        let deleted = recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "玉ねぎ"])
        let other = recipe(id: "b", name: "カレー", ingredients: ["じゃがいも", "玉ねぎ", "肉"])

        let result = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: deleted,
            remainingEntries: [entry(id: "e2", recipeId: "b")],
            recipesById: index([deleted, other])
        )

        #expect(result.isEmpty)
    }

    @Test("複数の残る献立をまたいで重複を判定する")
    func considersMultipleRemainingEntries() {
        let deleted = recipe(id: "a", name: "野菜炒め", ingredients: ["キャベツ", "にんじん", "ピーマン"])
        let b = recipe(id: "b", name: "サラダ", ingredients: ["キャベツ"])
        let c = recipe(id: "c", name: "きんぴら", ingredients: ["にんじん"])

        let result = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: deleted,
            remainingEntries: [entry(id: "e2", recipeId: "b"), entry(id: "e3", recipeId: "c")],
            recipesById: index([deleted, b, c])
        )

        // キャベツ(b)・にんじん(c)は残り、どちらにも無いピーマンだけ削除
        #expect(result == ["ピーマン"])
    }

    // MARK: - 端のケース

    @Test("同じレシピが別の日にも入っていれば全材料を残す")
    func keepsAllWhenSameRecipeRemainsOnAnotherDay() {
        let deleted = recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉"])

        // 削除対象と同じレシピを参照する別エントリが残っている
        let result = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: deleted,
            remainingEntries: [entry(id: "e2", recipeId: "a")],
            recipesById: index([deleted])
        )

        #expect(result.isEmpty)
    }

    @Test("参照先レシピが見つからない残エントリは材料なしとして扱う")
    func ignoresRemainingEntriesWithMissingRecipe() {
        let deleted = recipe(id: "a", name: "肉じゃが", ingredients: ["じゃがいも", "牛肉"])

        // recipeId "z" は recipesById に無い(レシピ削除済みなど)
        let result = MealPlanIngredientRemoval.namesToRemove(
            deletedRecipe: deleted,
            remainingEntries: [entry(id: "e2", recipeId: "z")],
            recipesById: index([deleted])
        )

        #expect(result == ["じゃがいも", "牛肉"])
    }
}
