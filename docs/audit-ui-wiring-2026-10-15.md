# Rà soát nối logic UI — 15/10/2026

## Cập nhật sau hoàn thiện 0.3.0

UI hiện nối đủ 11/11 lệnh backend: đã bổ sung nhập lịch sử có nguồn/đích và metadata Desktop tùy chọn, xác minh độc lập, trình xem báo cáo và nhật ký tối đa 100 thao tác. Có xác minh sau nhập; lỗi xác minh sau đồng bộ giữ các app đã đóng. Báo cáo có lỗi bản ghi dạng object được đọc đúng. Nguồn ngoài có writer nhìn thấy hoặc không kiểm tra được sẽ bị từ chối trước ghi và trước commit. Đây không phải khóa phối hợp với công cụ ngoài; vẫn cần đóng nguồn hoặc dùng bản sao offline.

Xác nhận cuối: 135 test Python, hai bộ Swift, build arm64 0.3.0/build 3 và kiểm tra app/ZIP/SHA256 đều pass. Tạo/sửa bundle Claude thật với dữ liệu mẫu qua bộ thử headless pass. Đã cài và mở Harbor 0.3.0, kiểm tra mở/đóng báo cáo qua UI thật, đối chiếu runtime nguồn và xác nhận registry/lựa chọn sync giữ nguyên. Bản 0.2.0 được giữ để quay lại.

Phép thử GUI với HOME tạm từng gây hộp thoại Keychain; đã dừng tiến trình thử và bỏ hoàn toàn việc mở Electron khỏi bộ thử. Keychain mặc định vẫn là login.keychain-db, Claude gốc hoạt động bình thường. Không coi phép thử đó là GUI acceptance pass. Đăng nhập OAuth, trả lời Code thật, mở lại clone sau repair và kiểm thử tải về/Gatekeeper còn cần môi trường thử riêng. User yêu cầu chỉ cập nhật Harbor, giữ lựa chọn profile; không sửa/sync profile thật. CI remote và phát hành chưa chạy; chưa có chứng chỉ Developer ID để notarize.

Các mục bên dưới là bằng chứng của **đợt rà soát trước khi bổ sung UI**, được giữ để truy vết.

## Kết luận đợt rà soát ban đầu

UI hiện gọi 10/11 lệnh backend. `import` chưa có giao diện. Các nút đang hiện có selector/đích xử lý thật; không có nút minh họa được phát hiện trong phạm vi rà soát. Điều này không đồng nghĩa mọi luồng đã được kiểm chứng với tài khoản Claude thật.

Phương pháp: đối chiếu command trong `manager.dispatch` với `Manager.request`, selector của button/menu, callback form và xử lý kết quả; chạy Python suite, hai chương trình test Swift, kiểm tra app/ZIP và review độc lập. Tất cả dữ liệu ghi trong test nằm trong thư mục tạm; không sync, repair hay đăng nhập tài khoản thật.

## Ma trận kết nối

| Logic | UI → xử lý | Mức bằng chứng |
|---|---|---|
| `capabilities` | Khởi động/Làm mới → kiểm tra version/features | Gọi runtime đã cài vào home tạm qua Swift |
| `status` | Khởi động/Làm mới/sau thao tác → dựng lại danh sách | Runtime tạm và kiểm tra render trạng thái |
| `select ID true/false` | Checkbox Đồng bộ → lưu backend → reload | `performClick` thực trên AppKit, dispatcher/runtime thật, đọc lại registry tạm |
| `create NAME KIND` | Form → callback → decode ID → mở app đúng ID | Đối chiếu source, test form validation/retry/reentrancy; test backend lỗi và rollback bằng fixture; chưa tạo Claude thật |
| Mở một/mọi app | Nút Mở/Mở tất cả/menu → `NSWorkspace.openApplication` | Đối chiếu selector và native API; chưa mở tài khoản thật |
| `doctor` | Kiểm tra/nút cảnh báo/menu → cập nhật health, hiển thị vấn đề | Runtime tạm với registry trống, test các health issue và nút Sửa |
| `repair ID` | Nút Sửa → xác nhận → backend → reload | Source, lỗi profile thiếu qua runtime thật, Python fixture giữ dữ liệu/rollback; chưa sửa clone thật |
| `recover` | Kiểm tra → Phục hồi khi có journal | Source, no-op trên runtime tạm, Python fixture phục hồi journal; chưa phục hồi dữ liệu thật |
| `check` | Trước sync và vòng chờ → đọc busy/running/errors | Source, hợp đồng lỗi trên runtime tạm, fixture từ chối ghi khi bận |
| `sync` | Nút/menu → check → chờ → đóng app → sync | Swift kiểm tra thứ tự với request stub; Python fixture kiểm tra fan-out, phân nhánh, rollback, binding, tombstone |
| `verify` | Tự chạy sau sync, trước mở lại | Swift kiểm tra thứ tự/thất bại, Python kiểm tra nội dung và lưu báo cáo; chưa có nút độc lập |
| `import` | Chưa có UI | CLI có source/target tường minh; không có request từ UI |
| Báo cáo & sao lưu | Mở thư mục dữ liệu qua Finder | Source native API; chưa có trình xem/chọn backup trong app |
| Chi tiết | Xem/chọn/sao chép thông báo hiện tại | Test native sheet mở/đóng và khôi phục controls |

## Lỗi tìm thấy và đã xử lý

1. Callback đóng Chi tiết có thể chạy khi `attachedSheet` còn khác nil, làm các nút giữ trạng thái disabled. Đã chuyển cập nhật controls sang lượt main queue kế tiếp; native regression test xác nhận sau đóng cửa sổ các nút được bật lại.
2. Báo cáo sync có `warnings` sai kiểu hoặc `pending` chứa phần tử không phải chuỗi làm Swift không decode được cả Summary. Đã kiểm tra toàn bộ trường mà Swift dùng, từ chối boolean/giá trị âm ở các bộ đếm; báo cáo hỏng bị bỏ qua mà không mất danh sách profile.
3. Kết quả verify thất bại trước đây chỉ còn generic error trên desktop. Hiện lưu `last-verification.json` dưới khóa, bằng atomic write và quyền `0600`, trước khi trả lỗi. Remediation dẫn đến file đó qua Báo cáo & sao lưu. File chứa chẩn đoán cục bộ, không được gửi ra ngoài.
4. Kiểm tra mở rộng gặp hai lần waiter Foundation đứng ở `waitUntilExit` dù child đã kết thúc. Đã thay bằng termination handler được cài trước launch và chỉ hoàn tất sau khi hai reader drain xong; test có 24 tiến trình Python ngắn liên tiếp. Test này không phải bảo đảm mọi tình huống hệ điều hành đều đã được kiểm chứng.
5. Child tạo descendant giữ pipe có thể kéo dài timeout dù child trực tiếp đã thoát. Fixture sleep 3 giây đã tái hiện; reader hiện poll và thoát khi timeout/output limit có hiệu lực. Test timeout 0,1 giây xác nhận không phải chờ descendant hết 3 giây. Không bổ sung thao tác kill toàn bộ process tree.

Test checkbox còn mô phỏng profile biến mất giữa render và click: runtime từ chối identity cũ, UI reload danh sách và giữ thông báo `profile_missing`.

## Phần còn thiếu và giới hạn xác nhận

- Form import lịch sử từ nguồn ngoài, chọn đích, chọn Desktop metadata: chưa có.
- Nút verify độc lập và trình xem chi tiết kết quả: chưa có; verify tự động và báo cáo file đã có.
- Trình xem/khôi phục một backup đã chọn: chưa có. Phục hồi hiện tại dành cho giao dịch dở dang.
- Timeline nhiều lần thao tác: chưa có; Chi tiết chỉ là thông báo hiện tại.
- Đăng nhập, đóng/mở Claude thật, tạo/sửa clone thật và toàn luồng sync với tài khoản thật: chưa chạy trong đợt rà soát này.
- GitHub CI mới được cấu hình; chưa có lần chạy remote cho thay đổi chưa push.

## Kết quả kiểm tra

- Python: 122 test pass.
- Swift backend/protocol/wiring: pass, bao gồm click thật xuống runtime tạm, các command contract, fast child, pipe timeout và đóng sheet.
- Swift form: pass (validation, retry, giữ dữ liệu, chống submit trùng, lỗi dài).
- Build arm64 và verifier app/ZIP/chữ ký/entitlement: pass với source sau các sửa lỗi rà soát.
