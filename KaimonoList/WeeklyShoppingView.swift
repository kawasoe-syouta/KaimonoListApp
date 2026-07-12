import SwiftUI

/// 週間まとめ買いビュー。今週(今日から7日分)の献立のうち、まだ買い物リストへ
/// 展開していない材料を品名で集約し、売り場(カテゴリ)順に一覧する。
/// 下部の「まとめてリストへ追加」で、1週間分の材料を一括で買い物リストへ追加できる。
struct WeeklyShoppingView: View {
    let viewModel: MealPlannerViewModel
    @Environment(\.dismiss) private var dismiss

    /// カテゴリ順にまとめた材料セクション。表示のたびに現在の献立から算出する
    private var sections: [MealPlannerViewModel.WeeklyShoppingSection] {
        viewModel.weeklyShoppingSections()
    }

    /// 集約後の材料の総品数(概要表示に使う)
    private var itemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "追加できる材料はありません",
                        systemImage: "cart",
                        description: Text("今週の献立の材料はすべてリストへ追加済みか、まだ献立が登録されていません。")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("週間まとめ買い")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
        }
    }

    private var list: some View {
        List {
            Section {
                LabeledContent("料理", value: "\(viewModel.pendingEntryCount)品")
                LabeledContent("材料", value: "\(itemCount)品目")
            } header: {
                Text("今週のまとめ買い")
            }

            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        WeeklyShoppingRow(item: item)
                    }
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("同じ品名がすでに未購入リストにある材料は追加されません(数量の合算はしません)。数量は献立の人数に合わせて調整しています。")
            }
        }
    }

    /// 下部固定の一括追加ボタン。材料が1件でもあるときだけ表示する
    @ViewBuilder
    private var addBar: some View {
        if !sections.isEmpty {
            Button {
                Task {
                    await viewModel.addAllPendingIngredients()
                    dismiss()
                }
            } label: {
                Label("まとめてリストへ追加", systemImage: "cart.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
        }
    }
}

// MARK: - 材料の行

/// 集約した材料1件。品名と、由来の料理名・スケール済みの数量の内訳を表示する
private struct WeeklyShoppingRow: View {
    let item: WeeklyShoppingAggregator.Item

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if !item.recipeNames.isEmpty {
                    Text(item.recipeNames.joined(separator: "・"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !item.quantities.isEmpty {
                Text(item.quantities.joined(separator: "・"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
