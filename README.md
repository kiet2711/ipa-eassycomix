# EasyComix Gemini — iOS Tweak & IPA Patcher

<p align="center">
  <strong>Tweak tích hợp Google Gemini AI và mở khóa tính năng PRO vĩnh viễn cho ứng dụng đọc & dịch truyện tranh EasyComix (iOS 18+).</strong>
</p>

---

## 📖 Giới thiệu

**EasyComix Gemini** là bản chỉnh sửa (Tweak dylib) dành cho ứng dụng **EasyComix** trên iOS. Tweak can thiệp trực tiếp vào luồng mạng (`NSURLProtocol`) và runtime Objective-C/Swift của ứng dụng để:
- Chuyển hướng toàn bộ yêu cầu dịch thuật (Dịch Chapter thường & Dịch Live cuộn trang) sang **Google Gemini API**.
- Tự động giả lập gói **PRO Lifetime** (hạn mức 999,999 lượt dịch, chặn quảng cáo, gỡ bỏ paywall).
- Hỗ trợ **Key Pool** với tính năng tự động xoay key khi bị giới hạn tốc độ (Rate Limit - HTTP 429).

---

## ✨ Tính năng nổi bật

- 🤖 **Dịch thuật bằng Google Gemini**:
  - `gemini-3.5-flash-lite` *(mặc định — thế hệ mới, dịch chuẩn ngữ cảnh thoại truyện tranh)*.
  - `gemini-3.1-flash-lite` *(tùy chọn tốc độ cao)*.
  - Tự động chuẩn hóa văn phong dịch truyện tranh, manga, manhwa, webtoon tự nhiên và giàu cảm xúc.
- 🔄 **Hệ thống Multi-Key (Key Pool) & Auto-Rotate tối ưu**:
  - Nhập nhiều Gemini API Key cùng lúc (tự động phân tích theo xuống dòng, phẩy, chấm phẩy, khoảng trắng, định dạng JSON/Text).
  - Tự động lọc sạch ký tự thừa, xóa key trùng lặp (Deduplicate) và đếm số lượng key hợp lệ theo thời gian thực.
  - Tự động xoay vòng key và thử lại ngay lập tức khi một key chạm giới hạn `429 (Too Many Requests)` hoặc lỗi kết nối.
- 💎 **Mở khóa PRO vĩnh viễn**:
  - Giả lập phản hồi RevenueCat và Backend Quota: **999,999 lượt** cho cả Dịch thường và Dịch Live.
  - Vô hiệu hóa quảng cáo (`ad-rules`).
  - Tự động bỏ qua các màn hình popup chặn đăng nhập/mua gói (`PaywallView`, `TrialFlow`, `LoginView`).
- 🔘 **Giao diện Cài đặt Chuyên nghiệp & Nút nổi**:
  - Nút **🤖 Key** tiện lợi có thể kéo thả bất kỳ đâu trên màn hình.
  - Popup cài đặt dạng Card hiện đại với `UITextView` nhiều dòng, nút **📋 Dán Clipboard**, **🧹 Dọn dẹp Key**, **🗑️ Xóa hết**, bộ chọn model và nút lưu cấu hình trực quan.
- ⚡ **Hỗ trợ Apple Shortcut**:
  - Tích hợp phím tắt iOS để hỗ trợ chụp ảnh màn hình và dịch truyện nhanh.

---

## 📲 Phím tắt iOS (Apple Shortcut)

Để sử dụng tính năng dịch nhanh qua phím tắt iOS, hãy cài đặt shortcut sau:

🔗 **[Tải EasyComix Shortcut](https://www.icloud.com/shortcuts/a6b75355116c4286977312f3337ad14b)**

---

## 🛠️ Hướng dẫn Build IPA

### Cách 1: Tự động qua GitHub Actions *(Khuyên dùng)*

> [!IMPORTANT]
> `Payload` chứa mã nhị phân ứng dụng đã giải mã. Hãy giữ repository ở chế độ **Private (Riêng tư)** để bảo mật.

1. Đưa mã nguồn cùng thư mục `Payload`, `EasyComixGemini.m`, `tools` và `.github` lên repository cá nhân.
2. Truy cập tab **Actions** trên GitHub.
3. Chọn workflow **Build EasyComix Gemini IPA** và bấm **Run workflow**.
4. Sau khi tiến trình hoàn tất, tải file IPA chưa ký tại mục **Artifacts** (`EasyComix-Gemini-unsigned`).
5. Ký file IPA bằng chứng chỉ của bạn trước khi cài vào thiết bị.

---

### Cách 2: Tự build trên macOS (Xcode)

**Yêu cầu:**
- macOS đã cài đặt Xcode (bao gồm `iPhoneOS SDK` iOS 18 trở lên).
- Python 3.

**Thực hiện:**

```bash
# Clone hoặc tải repository về máy
cd /path/to/easycomix-gemini

# Cấp quyền thực thi cho script
chmod +x tools/build_gemini_ipa.sh

# Build từ thư mục hiện tại (chứa Payload/)
bash tools/build_gemini_ipa.sh . ./EasyComix-Gemini-unsigned.ipa

# Hoặc truyền file IPA gốc
bash tools/build_gemini_ipa.sh ./EasyComix.ipa ./EasyComix-Gemini-unsigned.ipa
```

Script sẽ tự động:
1. Biên dịch `EasyComixGemini.m` thành `EasyComixGemini.dylib` (kiến trúc `arm64`).
2. Chèn lệnh `LC_LOAD_DYLIB` vào file thực thi của EasyComix thông qua `tools/inject_dylib.py`.
3. Xóa chữ ký số cũ và đóng gói thành file IPA unsigned.

---

## ✍️ Ký và Cài đặt lên iPhone / iPad

Do file IPA xuất ra là bản **Unsigned** (chưa ký), bạn cần ký lại trước khi cài đặt:

- **TrollStore** (iOS 14.0 – 17.0): Cài trực tiếp file IPA mà không cần chứng chỉ.
- **ESign / GBox / Scarlet**: Ký trực tiếp trên thiết bị bằng chứng chỉ cá nhân hoặc P12. *(Lưu ý: Bật tùy chọn ký kèm Frameworks/Dylib nhúng).*
- **Sideloadly / AltStore**: Cài đặt qua máy tính bằng Apple ID cá nhân.

---

## 🚀 Hướng dẫn cấu hình API Key trong App

1. Mở ứng dụng EasyComix đã cài đặt.
2. Lần đầu mở app (hoặc bấm vào nút nổi **🤖 Key** màu xanh trên màn hình), popup cài đặt sẽ hiển thị.
3. Dán một hoặc nhiều **Google Gemini API Key** (lấy miễn phí tại [Google AI Studio](https://aistudio.google.com/app/apikey)):
   - Hỗ trợ dán trực tiếp bằng nút **📋 Dán Clipboard**.
   - Bấm nút **🧹 Dọn dẹp Key** để tự động chuẩn hóa và loại bỏ key trùng lặp.
   ```text
   AIzaSyA1234567890...
   AIzaSyB0987654321...
   ```
4. Chọn model mong muốn:
   - **Gemini 3.5 Flash Lite**: Mặc định — thế hệ mới, dịch chuẩn ngữ cảnh thoại truyện tranh.
   - **Gemini 3.1 Flash Lite**: Tùy chọn tốc độ cao.
5. Bấm **💾 Lưu cấu hình**. Sau đó bạn có thể thưởng thức đọc và dịch truyện không giới hạn!

---

## 📂 Cấu trúc Repository

```text
├── .github/
│   └── workflows/
│       └── build-gemini-ipa.yml  # Workflow tự động build IPA trên macOS GitHub runner
├── Payload/                      # Thư mục ứng dụng EasyComix gốc đã giải mã
│   └── EasyComix.app/
├── tools/
│   ├── build_gemini_ipa.sh       # Script biên dịch dylib, inject và đóng gói IPA
│   └── inject_dylib.py          # Script chèn LC_LOAD_DYLIB vào Mach-O binary
├── EasyComixGemini.m             # Mã nguồn Tweak Hook (C/Objective-C)
├── BUILD_GEMINI_IPA.md           # Hướng dẫn build tóm tắt
├── link shortcut.txt             # Link Apple Shortcut dịch truyện
└── README.md                     # Tài liệu hướng dẫn chính
```

---

## ⚠️ Lưu ý & Xử lý sự cố

- **Lỗi HTTP 404 khi dịch**: Nếu chọn model 3.5 và gặp lỗi 404, hãy bấm nút **🤖 Key** và chuyển về `gemini-3.1-flash-lite`.
- **Lỗi HTTP 429 (Quá tải rate limit)**: Thêm từ 2–3 API key vào ô nhập để tweak tự động xoay vòng key khi gọi API.
- **Yêu cầu iOS**: Ứng dụng yêu cầu thiết bị chạy **iOS 18.0 trở lên** giống phiên bản gốc.
- **Bảo mật**: Không chia sẻ file IPA đã đóng gói có chứa sẵn API Key cá nhân của bạn ra bên ngoài.

---

## 📄 Tuyên bố miễn trừ trách nhiệm (Disclaimer)

Dự án này được tạo ra nhằm mục đích học tập, nghiên cứu kỹ thuật can thiệp runtime Objective-C và giao thức mạng trên iOS. Tác giả không chịu trách nhiệm cho bất kỳ hành vi lạm dụng hoặc vi phạm điều khoản dịch vụ nào từ phía bên thứ ba.
