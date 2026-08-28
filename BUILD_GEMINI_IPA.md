# Build EasyComix dùng Gemini

Tweak chặn request dịch của EasyComix, gửi mảng câu sang Gemini rồi trả kết quả về đúng cấu trúc mà app đang dùng.

## Model trong giao diện

- `gemini-2.5-flash-lite` — mặc định.
- `gemini-3.5-flash-lite` — chỉ hoạt động nếu Gemini API thực sự cung cấp model này cho API key/tài khoản của bạn.

Nhấn nút nổi **🤖 Key**, nhập một hoặc nhiều Gemini API key (phân cách bằng dấu phẩy hoặc xuống dòng), rồi nhấn model muốn dùng. API key và model được lưu trong UserDefaults của app.
Tweak tự động giả lập gói **PRO vĩnh viễn** (999,999 lượt cho cả Dịch Chapter thường và Dịch Live).

## Build bằng GitHub Actions

1. Đưa `Payload`, `EasyComixGemini.m`, `tools` và workflow vào repository riêng tư. Payload chứa mã ứng dụng đã giải mã; không nên đăng lên repository công khai.
2. Mở tab **Actions**, chạy workflow **Build EasyComix Gemini IPA**.
3. Tải artifact `EasyComix-Gemini-unsigned`.
4. Ký IPA bằng chứng chỉ của bạn trước khi cài.

## Build trực tiếp trên macOS

Yêu cầu Xcode có iPhoneOS SDK:

```bash
bash tools/build_gemini_ipa.sh . ./EasyComix-Gemini-unsigned.ipa
```

Có thể truyền một IPA gốc thay cho dấu `.`:

```bash
bash tools/build_gemini_ipa.sh ./EasyComix.ipa ./EasyComix-Gemini-unsigned.ipa
```

Script build dylib arm64, chèn `LC_LOAD_DYLIB`, xóa chữ ký cũ và đóng gói IPA unsigned. Công cụ ký/sideload phải ký cả app lẫn dylib nhúng.

## Lưu ý

- Không nhúng API key trực tiếp vào IPA.
- Nếu model 3.5 trả HTTP 404, chuyển về Gemini 2.5 Flash Lite.
- IPA yêu cầu iOS 18 trở lên giống ứng dụng gốc.
