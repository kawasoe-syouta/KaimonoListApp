import Testing
@testable import KaimonoList

/// IngredientScaler の「材料数量を人数比でスケールする」挙動の検証。
/// 自由入力の数量から最初の数値だけを比率倍し、単位や非数値はそのまま残すことを確認する。
struct IngredientScalerTests {

    // MARK: - 基本の倍率

    @Test("グラム表記を倍率どおりにスケールする")
    func scalesGrams() {
        #expect(IngredientScaler.scale("200g", from: 2, to: 4) == "400g")
        #expect(IngredientScaler.scale("300ml", from: 2, to: 1) == "150ml")
    }

    @Test("数値が単位の後ろにあってもスケールする(大さじ2 など)")
    func scalesTrailingNumber() {
        #expect(IngredientScaler.scale("大さじ2", from: 2, to: 4) == "大さじ4")
        #expect(IngredientScaler.scale("2個", from: 2, to: 6) == "6個")
    }

    // MARK: - 分数・端数

    @Test("分数表記をスケールし、割り切れれば整数にする")
    func scalesFraction() {
        #expect(IngredientScaler.scale("1/2本", from: 2, to: 4) == "1本")
        #expect(IngredientScaler.scale("1/4個", from: 2, to: 4) == "0.5個")
    }

    @Test("端数は小数で表す(末尾の0は落とす)")
    func formatsFraction() {
        #expect(IngredientScaler.scale("1本", from: 2, to: 3) == "1.5本")
        #expect(IngredientScaler.scale("1.5本", from: 2, to: 4) == "3本")
    }

    // MARK: - スケールしないケース

    @Test("数値を含まない数量はそのまま返す")
    func keepsNonNumeric() {
        #expect(IngredientScaler.scale("適量", from: 2, to: 4) == "適量")
    }

    @Test("人数が同じ・不正なら原文のまま")
    func noChangeWhenSameOrInvalid() {
        #expect(IngredientScaler.scale("200g", from: 2, to: 2) == "200g")
        #expect(IngredientScaler.scale("200g", from: 0, to: 4) == "200g")
        #expect(IngredientScaler.scale("200g", from: 2, to: 0) == "200g")
    }

    @Test("nil はそのまま nil")
    func keepsNil() {
        #expect(IngredientScaler.scale(nil, from: 2, to: 4) == nil)
    }

    @Test("最初の数値だけをスケールする")
    func scalesOnlyFirstNumber() {
        // 先頭の "2" のみ倍率対象(単位語尾などの余計な数値には触れない想定)
        #expect(IngredientScaler.scale("2袋", from: 2, to: 4) == "4袋")
    }
}
