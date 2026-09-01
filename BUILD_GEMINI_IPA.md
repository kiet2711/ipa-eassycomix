# Build EasyComix dùng Gemini

Tweak chặn request dịch của EasyComix, gửi mảng câu sang Gemini rồi trả kết quả về đúng cấu trúc mà app đang dùng.

## Model trong giao diện

- `gemini-3.5-flash-lite` — mặc định (thế hệ mới, dịch chuẩn ngữ cảnh truyện tranh).
- `gemini-3.1-flash-lite` — tùy chọn tốc độ cao.

Nhấn nút nổi **🤖 Key**, dán danh sách Gemini API key vào ô nhập (hỗ trợ dán từ clipboard, dọn dẹp key tự động, xoay key vòng tròn khi gặp lỗi Rate Limit 429), sau đó chọn model và nhấn **Lưu cấu hình**.
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
- Nếu model 3.5 trả HTTP 404, chuyển sang Gemini 3.1 Flash Lite.
- IPA yêu cầu iOS 18 trở lên giống ứng dụng gốc.
