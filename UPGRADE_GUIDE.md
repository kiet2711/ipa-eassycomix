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

## 5. Tính năng "Dịch Live" (Quay màn hình) & Giải pháp App Group Patch

* **Cách hoạt động**: EasyComix sử dụng ReplayKit Extension (`Payload/EasyComix.app/PlugIns/EasyComixBroadcast.appex`). Extension chụp ảnh màn hình ➔ lưu vào App Group dùng chung ➔ gửi thông báo Darwin Notification ➔ App chính đọc ảnh từ App Group và hiển thị bản dịch lên cửa sổ nổi **Picture-in-Picture (PiP)**.
* **Nguyên nhân lỗi khi Sideload / ESign**:
  * App Group gốc là `group.app.easycomix` thuộc Developer Team gốc `S465Y7V68Z`.
  * Khi ký lại bằng chứng chỉ khác (ví dụ Team ID `7RS63NZFBW`), iOS Sandbox chặn quyền truy cập App Group này khiến `containerURLForSecurityApplicationGroupIdentifier:` trả về `nil`.
* **Giải pháp Patch toàn diện (Đã tích hợp trong `tools/patch_binary.py` và `EasyComixGemini.m`)**:
  1. **Patch mã máy Swift ARM64 & Chuỗi dữ liệu**:
     * App Group mặc định được đổi sang: `group.7RS63NZFBW.cvN` (20 ký tự).
     * `Payload/EasyComix.app/EasyComix`:
       - Offset `0x468b00`: Ghi đè chuỗi `group.7RS63NZFBW.cvN\0` (trong slot 32-byte).
       - Offset `0x24c3a4`: Sửa lệnh nạp độ dài Swift String từ `mov x0, #19` (`60 02 80 d2`) thành `mov x0, #20` (`80 02 80 d2`).
     * `Payload/EasyComix.app/PlugIns/EasyComixBroadcast.appex/EasyComixBroadcast`:
       - Offset `0x65f0`: Ghi đè chuỗi `group.7RS63NZFBW.cvN\0`.
       - Offset `0x40a8`: Sửa lệnh nạp độ dài Swift String từ `mov x0, #19` (`60 02 80 d2`) thành `mov x0, #20` (`80 02 80 d2`).
  2. **Runtime Defense (Dự phòng trong Dylib)**:
     * `EasyComixGemini.m` swizzle `containerURLForSecurityApplicationGroupIdentifier:` để tự động chuyển hướng mọi yêu cầu từ `group.app.easycomix` sang `group.7RS63NZFBW.cvN`.
* **Hướng dẫn cấu hình khi ký trên ESign / GBox / zsign**:
  * **TUYỆT ĐỐI KHÔNG BẬT**: *"Xóa PlugIn / Extension"* (giữ lại `EasyComixBroadcast.appex`).
  * **TUYỆT ĐỐI TẮT**: *"Xóa embedded.mobileprovision sau ký"*.
  * **Entitlements**: Sử dụng file mẫu [tools/entitlements.plist](file:///d:/ipa/tools/entitlements.plist) chứa:
    ```xml
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.7RS63NZFBW.cvN</string>
    </array>
    <key>com.apple.developer.kernel.increased-memory-limit</key>
    <true/>
    ```
* **Môi trường hỗ trợ**:
  * **TrollStore (iOS 14 - 17.0)**: Chạy 100% không cần chứng chỉ.
  * **ESign / Sideload có chứng chỉ hỗ trợ App Groups (như cert 7RS63NZFBW)**: Chạy 100% Live Translate sau khi áp dụng bản patch trên.

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
