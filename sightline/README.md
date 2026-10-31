<!-- labels: important -->
# Sightline

為盲人與低視能使用者開發的室內取物輔助 iOS 原型。說出想找的物件，系統透過語意辨識、LiDAR 與手部追蹤協助接近，再由使用者觸覺探索並選擇自己的握法。

專案始於 Meta Global AI Developer Hackathon（2026-10-26 至 11-04）。目前是研發原型；2026-10-30 的人因與控制修訂尚待 iPhone 與視障使用者驗證。

## 使用流程

1. 將 iPhone 固定胸前，選擇要使用的手，依語音量測舒適伸手距離。每次重新佩戴或 App 離開前景後重新量測。
2. 說出物件。目標超出量測範圍、無法測量表面或追蹤不可靠時，系統停止動作引導。
3. 保持身體不動，按照分階段提示接近可見近側；障礙可中止整段引導。
4. 系統提示「接觸尚未確認」，由使用者觸覺探索和握持。
5. 選擇 Check。自動確認最多觀察三次，需兩次身份肯定與至少兩個相同指尖的共同移動證據；只提示一次小幅水平移動，仍不足就結束確認。使用者也可自行確認。

主要區域在閒置時開始聆聽，任務期間一律停止。另有固定 Stop、Status、Check、自行確認與 Reach setup 控制。掃描時用 Finish scan 儲存，Stop 放棄掃描。

## 技術

| 元件 | 工作 |
|---|---|
| Muse Spark | 事件觸發的語意理解、候選選擇與影像比對 |
| SAM 3.1 | 事件觸發的目標分割；遮罩不是抓取品質證明 |
| ARKit / LiDAR | 相機定位、可見表面與當前障礙點雲 |
| Vision | 手部關節；引導使用同一個實際指尖 |
| 本機狀態機 | 舒適距離、分階段接近、障礙否決、停止和語音節流 |

本機動作控制不等待網路；雲端確認期間停止動作提示。每搜尋最多一個確認循環，每循環最多三次 SAM 與三次身份比對、三十五秒時限；單張漏檢可補取觀測，仍不足就提供自行確認、New search、Stop，不降級為單模型成功。

## 驗證與文件

- [產品規格](docs/PRD.md)
- [十項問題、修正與限制](docs/HUMAN_FACTORS.md)
- [目前實機與使用者測試步驟](docs/FIND_TEST.md)
- [歷史測試紀錄](docs/TEST_LOG.md)
- [研發驗證清單](docs/SPIKE.md)

本機邏輯測試：`swift test --package-path Packages/SightlineCore`。
模擬器：`swift run --package-path Packages/SightlineCore SightlineSim`。它使用合成使用者與簡化感測，不能證明真實安全或視障使用成效。

## 使用邊界與相關研究

僅限靜止身體的室內可及範圍探索；不能替代白手杖、導盲犬或行走導航。透明、反光、遮擋、薄小物件與深度誤差仍會造成漏檢。沒有經驗證的避障繞行、握力或安全抓取點預測。

相關研究包括 [PalmSight](https://publications.ri.cmu.edu/palmsight-an-assistive-technology-helping-the-blind-to-locate-and-grasp-objects)，以及 PRD 記錄的 NaviSense 與 AIGuide；不聲稱首創手部取物引導。
