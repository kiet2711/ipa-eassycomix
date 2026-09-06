# EasyComix Gemini - Tài liệu Kỹ thuật & Hướng dẫn Nâng cấp (Upgrade & Maintenance Guide)

> **Dành cho AI / Lập trình viên:**  
> Tài liệu này ghi lại toàn bộ kiến trúc, các bản vá mã máy (Binary Patches), các hàm can thiệp (Dylib Hooks) và quy trình từng bước để nâng cấp dự án khi ứng dụng **EasyComix** ra mắt phiên bản mới (1.0.27+).

---

## 1. Tổng quan Kiến trúc Dự án

EasyComix là ứng dụng đọc và dịch truyện tranh / tiểu thuyết trên iOS. Dự án này chuyển hướng toàn bộ hệ thống dịch từ máy chủ trả phí của tác giả sang **Google Gemini API** hoàn toàn miễn phí.

### Cấu trúc các thành phần:
* **`Payload/EasyComix.app/EasyComix`**: File thực thi gốc (Mach-O 64-bit arm64). Được viết chủ yếu bằng Swift.
* **`Payload/EasyComix.app/PlugIns/EasyComixBroadcast.appex`**: ReplayKit Broadcast Upload Extension phục vụ tính năng "Dịch Live" (quay màn hình).
* **`EasyComixGemini.m`**: Mã nguồn Objective-C biên dịch thành `EasyComixGemini.dylib`, nhúng vào `Payload/EasyComix.app/Frameworks/`.
* **`tools/patch_binary.py`**: Script can thiệp trực tiếp vào mã máy của file thực thi gốc `EasyComix`.
* **`tools/inject_dylib.py`**: Script chèn lệnh `LC_LOAD_DYLIB` vào Mach-O header để app gốc tự nạp `EasyComixGemini.dylib`.
* **`tools/build_gemini_ipa.sh`**: Script tự động hóa toàn bộ quy trình biên dịch dylib, vá binary, tiêm dylib và đóng gói IPA.
* **`.github/workflows/build-gemini-ipa.yml`**: GitHub Actions CI build IPA trên môi trường `macos-15`.

---

## 2. Chi tiết các can thiệp mã máy (Binary Patching)

Từ phiên bản **1.0.26 (Build 69)**, tác giả đã bổ sung cơ chế kiểm tra chữ ký mã hóa của máy chủ bằng **Swift + Apple CryptoKit** (`verifyServerResponse`). Do code Swift được biên dịch tĩnh (static inline), dylib không thể hook toàn diện nếu không vá mã máy.

File `tools/patch_binary.py` thực hiện **4 bản vá Assembly (ARM64)** trực tiếp vào `EasyComix`:

| Địa chỉ (VM / File Offset) | Byte gốc (Original ASM) | Byte vá mới (Patched ASM) | Mục đích kỹ thuật |
| :--- | :--- | :--- | :--- |
| **`0x1001b1888`**<br>(offset: `0x1b1888`) | `bl #0x1001b338c`<br>`cbnz x21, ...` | `b #0x1001b19cc`<br>`nop`<br>(`51 00 00 14 1f 20 03 d5`) | **Caller Bypass**: Bỏ qua hoàn toàn khối lệnh gọi hàm `verifyServerResponse` và nhảy thẳng tới đoạn xử lý dữ liệu hợp lệ. |
| **`0x1001b338c`**<br>(offset: `0x1b338c`) | `sub sp, sp, #0x180`<br>`stp x28, x27, ...` | `mov x21, xzr`<br>`ret`<br>(`bf 03 1f aa c0 03 5f d6`) | **Callee Early Exit**: Ngay đầu hàm `verifyServerResponse`, gán `x21 = 0` (mã lỗi nil / không lỗi) và return ngay lập tức. |
| **`0x10045a4b8`**<br>(offset: `0x45a4b8`) | `ldr x8, [x8, #0x28]`<br>`br x8` | `mov w0, #1`<br>`ret`<br>`nop`<br>(`20 00 80 52 c0 03 5f d6 1f 20 03 d5`) | **CryptoKit Stub**: Hàm kiểm tra chữ ký `isValidSignature` luôn trả về `true` (1). |
| **`0x1001b37f8`**<br>(offset: `0x1b37f8`) | `tbz w8, #0, #0x1001b3804` | `nop`<br>(`1f 20 03 d5`) | **Check Bypass**: Triệt tiêu điều kiện rẽ nhánh kiểm tra lỗi chữ ký. |

### Cách tìm lại các offset này khi app cập nhật bản mới:
1. Dùng công cụ disassembly (Ghidra, IDA Pro, Radare2, Capstone):
   * Tìm chuỗi định danh: `_stringCompareWithSmolCheck`, `APIError`, `CryptoKit`, `verifyServerResponse`.
   * Tìm các cross-references tới header `Content-Type` hoặc mã lỗi `case2` của enum APIError.
2. Cập nhật lại các offset trong `tools/patch_binary.py`.

---

## 3. Chi tiết can thiệp trong Dylib (`EasyComixGemini.m`)

File `EasyComixGemini.m` sử dụng **Objective-C Runtime Method Swizzling** can thiệp vào `NSURLSession`:

### Các Endpoints được chặn & giả lập:
1. **Kiểm tra phiên bản**:
   * Chặn API check update, trả về `latestVersion = "1.0.26"` (hoặc phiên bản hiện tại) để ngăn popup bắt buộc cập nhật.
2. **Tài khoản & Hạn mức (`/api/v1/user/me`, `/quota`)**:
   * Trả về thông tin VIP vĩnh viễn: `isVip = true`, `expireDate = 4102444800` (năm 2100), số lượt dịch không giới hạn (`tokenCount = 999999`).
3. **Dịch Manga / Web (`/api/v1/translate`)**:
   * Trích xuất danh sách text cần dịch, gửi request tới **Google Gemini API** (`gemini-1.5-flash` hoặc `gemini-2.0-flash`).
   * Định dạng lại JSON trả về khớp 100% cấu trúc máy chủ EasyComix mong đợi.
4. **Dịch Tiểu thuyết mới của 1.0.26 (`/api/v1/novel/translate`)**:
   * Bổ sung bộ xử lý novel: dịch từng đoạn văn bản giữ nguyên cấu trúc dòng.

### ⚠️ Gotcha cực kỳ quan trọng (Crucial Bug Fix):
* **Header `Content-Type`**: Khi giả lập response `NSHTTPURLResponse`, header `Content-Type` **BẮT BUỘC PHẢI LÀ EXACT** `@"application/json"`.
* **KHÔNG ĐƯỢC DÙNG**: `@"application/json; charset=utf-8"`.
* **Lý do**: Hàm Swift trong app gốc dùng `_stringCompareWithSmolCheck` để so sánh chuỗi chính xác tuyệt đối. Nếu có đuôi `charset=utf-8`, app sẽ coi là header không hợp lệ và quăng lỗi `APIError.case2`.

---

## 4. Cơ chế nạp Dylib (`tools/inject_dylib.py`)

* Script đọc cấu trúc Mach-O của binary `Payload/EasyComix.app/EasyComix`.
* Mở rộng `sizeofcmds` và tăng `ncmds`.
* Thêm một `LC_LOAD_DYLIB` command với đường dẫn:  
  `@executable_path/Frameworks/EasyComixGemini.dylib`
* Nhờ đó, file dylib được nạp tự động vào không gian bộ nhớ của app ngay khi khởi chạy mà không cần jailbreak hay công cụ tiêm bên ngoài.

---

## 5. Tính năng "Dịch Live" (Quay màn hình) & Hạn chế

* **Cách hoạt động**: EasyComix sử dụng ReplayKit Extension (`Payload/EasyComix.app/PlugIns/EasyComixBroadcast.appex`). Extension chụp ảnh màn hình ➔ lưu vào App Group `group.app.easycomix` ➔ thông báo cho app chính đọc ảnh và hiển thị bản dịch lên cửa sổ nổi **Picture-in-Picture (PiP)**.
* **Hạn chế khi Sideload / Esign**:
  * App Group yêu cầu Team ID trong provisioning profile phải trùng khớp với Team ID gốc (`S465Y7V68Z`).
  * Khi ký bằng chứng chỉ mua doanh nghiệp (Team ID khác), iOS Sandbox sẽ chặn quyền truy cập `group.app.easycomix` (trả về `nil`).
  * **Hậu quả**: Chức năng quay màn hình vẫn chạy, nhưng ảnh không gửi sang app chính được nên không hiện chữ dịch.
  * **Môi trường hỗ trợ 100% Dịch Live**: Chỉ chạy được trên **App gốc App Store** hoặc thiết bị cài qua **TrollStore** (do TrollStore có khả năng fake quyền App Group).
* **Lưu ý khi ký trên Esign**:
  * Tuyệt đối **TẮT** mục `"Xóa embedded.mobileprovision sau ký"`. Nếu bật, iOS sẽ xóa profile khiến Extension bị tước toàn bộ quyền.
  * Giữ **TẮT** `"Xóa tất cả plugin"`.

---

## 6. Quy trình từng bước nâng cấp khi App ra bản mới (1.0.27+)

Khi có bản cập nhật mới từ App Store:

### Bước 1: Trích xuất và cập nhật thư mục `Payload`
1. Dùng công cụ giải mã (Decrypted IPA từ ArmConverter / decrypted store) để lấy thư mục `Payload` của bản mới.
2. Xóa thư mục `Payload/` cũ trong repo và thay bằng `Payload/` mới.

### Bước 2: Phân tích Binary mới (`EasyComix`)
1. Mở file `Payload/EasyComix.app/EasyComix` bằng công cụ phân tích (Ghidra / IDA / Radare2 / Capstone).
2. Kiểm tra xem hàm `verifyServerResponse` và `isValidSignature` nằm ở offset nào:
   * Tìm chuỗi `verifyServerResponse` hoặc tìm hàm tương tự ở bản cũ.
   * Lấy địa chỉ hàm mới (hoặc kiểm tra xem cấu trúc có thay đổi không).
3. Cập nhật lại các offset trong `tools/patch_binary.py`:
   ```python
   # Cập nhật địa chỉ mới trong tools/patch_binary.py:
   caller_offset = <offset_mới>
   callee_offset = <offset_mới>
   cryptokit_stub_offset = <offset_mới>
   ```

### Bước 3: Cập nhật mã nguồn `EasyComixGemini.m`
1. Cập nhật hằng số phiên bản:
   ```objc
   // Đổi sang phiên bản mới
   @"latestVersion": @"1.0.27"
   ```
2. Kiểm tra xem bản mới có thêm endpoint dịch mới nào không:
   * Nếu có thêm loại truyện/tính năng dịch mới, bổ sung logic hook URL vào `EasyComixGemini.m`.
3. Giữ nguyên quy tắc: Header `Content-Type` luôn là `@"application/json"`.

### Bước 4: Kiểm tra Script đóng gói (`tools/build_gemini_ipa.sh`)
* Đảm bảo đường dẫn Frameworks, cách gọi `patch_binary.py` và `inject_dylib.py` vẫn tương thích với file thực thi mới.

### Bước 5: Build và kiểm thử
1. Push commit lên GitHub branch `main`.
2. Chạy workflow **Build EasyComix Gemini IPA** trong tab Actions.
3. Tải file `EasyComix-Gemini-unsigned.ipa` từ Artifacts.
4. Ký file bằng Esign (nhớ tắt *Xóa embedded.mobileprovision*) và cài đặt lên máy để trải nghiệm.
