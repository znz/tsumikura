namespace :stock do
  desc "キャッシュ (在庫数・ロット残数) と台帳の差異を検出する (差異があれば異常終了)"
  task verify: :environment do
    differences = Stock::Verifier.call

    if differences.empty?
      puts "キャッシュと台帳の差異はありません (品目 #{Item.count} 件)。"
    else
      puts "#{differences.size} 件の差異が見つかりました。bin/rails stock:recalculate で直せます。"
      differences.each { |difference| puts difference }
      exit 1
    end
  end

  desc "全品目のキャッシュ (在庫数・ロット残数) を台帳から再計算する"
  task recalculate: :environment do
    count = 0
    failures = []

    # 1 品目の失敗 (check 制約違反など) で全体を止めない。
    # 直せなかった品目だけを最後に並べて、そこから調べられるようにする
    Item.find_each do |item|
      begin
        Stock::Recalculator.call(item)
        count += 1
      rescue StandardError => e
        failures << "品目 ##{item.id}「#{item.name}」: #{e.class}: #{e.message.lines.first&.strip}"
      end
    end

    puts "#{count} 件の品目のキャッシュを再計算しました。"

    if failures.any?
      puts "#{failures.size} 件の品目を再計算できませんでした。"
      failures.each { |failure| puts failure }
      exit 1
    end
  end
end
