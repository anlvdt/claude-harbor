# Nghiên cứu AI Switch Desktop và bài học cho Claude Harbor

Ngày nghiên cứu: 15/10/2026.

Nguồn: [burakdede/aisw-desktop](https://github.com/burakdede/aisw-desktop), snapshot `93bc5c0b9a579268183b8d42e5cb9a86b83eccb2` trên nhánh `main` khi tải về. `package.json` ghi phiên bản `0.2.1`; README vẫn mô tả sản phẩm ở giai đoạn alpha. Harbor được đối chiếu tại commit `75dc3e3f070819bfdc74a46f04a91befa45eed4f`.

Phương pháp: đọc trực tiếp source, tài liệu kiến trúc, bridge, schema, state, tests, workflow và screenshot được lưu trong repo. Hai repo chưa có trong danh sách index GitNexus tại thời điểm nghiên cứu nên dùng source trực tiếp. Không chạy ứng dụng, đăng nhập, đổi tài khoản, build hoặc chạy test suite của repo tham khảo. Những nhận xét dưới đây là kết quả đọc mã, không phải chứng nhận tương thích với tài khoản thật. Backend `aisw` là repo riêng, chưa được audit trong nghiên cứu này.

## 1. Kết luận

Giá trị lớn nhất để học là cách biến một runtime thành sản phẩm desktop: hợp đồng dữ liệu rõ ràng, trạng thái thao tác nhất quán, chẩn đoán có hướng xử lý và kiểm tra bản phát hành bằng mã.

Đề xuất giữ Swift/AppKit + Python của Harbor. Việc đổi sang Tauri/React chưa có lợi ích đủ rõ từ nghiên cứu này. Harbor đã có nhiều cơ chế an toàn dữ liệu phù hợp với bài toán đồng bộ; nên bổ sung tính dễ quan sát và hợp đồng giữa các lớp trước.

## 2. Hai sản phẩm khác nhau ở đâu?

| Khía cạnh | AI Switch Desktop | Claude Harbor hiện tại |
|---|---|---|
| Nhu cầu chính | Quản lý, chọn danh tính coding-agent qua runtime `aisw` | Chạy các bản Claude Desktop độc lập, đồng bộ Code local giữa profile được chọn |
| Công cụ | Claude Code, Codex CLI, Gemini CLI, Antigravity CLI | Claude Desktop; preset Magpie thử nghiệm |
| Giao diện/native | React/TypeScript → Tauri → Rust | AppKit/Swift → Python |
| Thực thi nghiệp vụ | Runtime `aisw` riêng, chọn bundled/system/custom | Backend Python được đóng gói và cài theo generation |
| Khái niệm nhóm | Profile set ánh xạ từng công cụ sang profile | Tập profile được cho phép chia sẻ lịch sử |
| An toàn ghi | Queue ở frontend, mutex ở native; runtime chịu trách nhiệm nghiệp vụ | Khóa file giữa process, launch lease, journal, backup và rollback |

Không suy diễn rằng đổi tài khoản CLI tương đương cô lập Claude Desktop. Cũng không diễn giải `shared` của AI Switch thành cơ chế đồng bộ lịch sử của Harbor.

Nguồn: [kiến trúc AI Switch](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/docs/architecture.md), [README Harbor](../README.md).

## 3. Luồng kiến trúc đáng học

```text
React feature panel
  → client.ts / tauri.ts: lời gọi có kiểu dữ liệu
  → commands.rs: bề mặt command tường minh
  → state.rs: điều phối mutation và tạo snapshot
  → bridge.rs: chạy aisw, parse JSON, ánh xạ lỗi
  → aisw runtime: auth, switching, backup, verify, repair
```

`schemas.ts` dùng Zod để mô tả dữ liệu frontend. Rust dùng các model có kiểu và lỗi có cấu trúc. `state.rs` kiểm tra CLI API version, JSON schema version và các feature bắt buộc; bootstrap không tải snapshot nếu runtime không tương thích. Đây là kiểm tra compatibility ở bootstrap, không phải bằng chứng rằng mọi command đều được kiểm tra lại trước mỗi lần ghi.

Harbor đã đặt phần lớn nghiệp vụ ở Python và decode JSON bằng Swift. Khoảng trống đáng bổ sung là phiên bản protocol, danh sách capability và lỗi có mã ổn định. Hash generation hiện tại chứng minh bộ runtime được chọn theo nội dung; nó chưa mô tả khả năng tương thích của giao thức với UI.

Nguồn: [state.rs](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/state.rs), [schemas.ts](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src/lib/schemas.ts).

## 4. Bài học cụ thể và cách áp dụng

### A. Lỗi có mã và hướng xử lý — ưu tiên cao

`ErrorPayload` gồm `kind`, `message`, `remediation`, `code`. UI có thể hiển thị cách xử lý dựa vào mã thay vì đoán từ chuỗi stderr.

Harbor có `HealthIssue.code`, nhưng lỗi command tổng quát vẫn đi qua stderr → NSError. Có thể thống nhất mã như `profiles_running`, `pending_recovery`, `clone_stale`, `protocol_incompatible`, kèm chi tiết đã lọc. Swift chọn nội dung tiếng Việt và thao tác hợp lệ từ mã; backend tiếp tục là nơi quyết định thao tác có được phép chạy.

Tiêu chí nghiệm thu gợi ý: lỗi giữ nguyên mã qua CLI và Swift; lỗi không biết vẫn đọc được; không đưa transcript hoặc credential vào thông báo.

Nguồn: [errors.rs](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/errors.rs).

### B. Điều phối thao tác và cập nhật trạng thái — ưu tiên cao

`mutationQueue.ts` xếp mutation nối tiếp, công bố nhãn thao tác và số lệnh chờ; các query dùng hook liên quan có thể tạm dừng khi queue bận. `state.rs` thêm mutex cho các mutation đi qua helper, giúp thao tác từ tray và cửa sổ cùng được điều phối. Sau mutation, runtime snapshot được tải lại; frontend cũng có helper invalidate các query liên quan.

Harbor đã có `working`, `waiting`, khóa file và launch lease. Bài học là làm rõ trạng thái hiển thị: kiểm tra → chờ trả lời → đóng app → đồng bộ → xác minh → mở lại, cùng kết quả sau cùng. Khóa liên process hiện tại vẫn cần giữ; queue trong UI không thay thế được nó. Chưa cần tự động xếp mọi yêu cầu ghi, vì yêu cầu chờ có thể dựa trên lựa chọn profile đã cũ.

Tiêu chí nghiệm thu gợi ý: tray và cửa sổ hiển thị cùng thao tác; không hiển thị thành công trước khi reload kết quả; phân biệt lỗi đồng bộ với lỗi mở lại app; chỉ cho dừng ở giai đoạn có thể dừng an toàn.

Nguồn: [mutationQueue.ts](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src/features/shared/mutationQueue.ts), [postMutationRefresh.ts](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src/features/shared/postMutationRefresh.ts).

### C. Trạng thái sức khỏe và hành động ngay tại profile — ưu tiên cao

Screenshot lưu trong repo thể hiện danh sách bên trái, chi tiết đối tượng đang chọn bên phải, cảnh báo tổng quan và kết quả thao tác gần nhất. Source có các feature riêng cho Diagnostics, Backups, Activity, Profiles và Sets. Screenshot là tài liệu minh họa được đóng gói cùng repo, chưa phải xác minh giao diện đang chạy.

Harbor hiện hiển thị ready/running, số session và hộp thoại doctor; nút báo cáo mở thư mục dữ liệu. Có thể cải thiện trước bằng trạng thái từng profile: chờ đăng nhập, chưa khởi tạo Code, clone cần sửa, có giao dịch cần phục hồi. Mỗi trạng thái dẫn đến thao tác có phạm vi rõ và lỗi tương ứng. Tách lịch sử thao tác khỏi báo cáo kỹ thuật để người dùng hiểu lần sync vừa rồi đã làm gì.

Không cần sao chép toàn bộ sidebar bảy mục vào một tiện ích nhỏ. Danh sách profile với vùng chi tiết hoặc cửa sổ báo cáo riêng có thể đủ.

Nguồn: [ảnh Overview](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/docs/media/desktop-overview-hero.png), [activity-store.ts](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src/features/shared/activity-store.ts).

### D. Contract test với runtime thật và release verifier — ưu tiên cao

`bridge_contract_tests.rs` gọi binary `aisw` thật trong thư mục tạm, với home/config riêng và CLI stub. Test kiểm tra payload bridge thực sự parse thay vì chỉ dựa vào mock. CI có job đa nền tảng, pin `AISW_VERSION=0.3.10`, tải checksum sidecar và so SHA-256; có chạy nhóm test `real_aisw`. `verify-release.mjs` kiểm tra các quy ước workflow, permission và packaging.

Harbor đã có Python regression tests và Swift process tests. Phần đáng bổ sung là test tích hợp Swift → dispatcher → generation Python được cài trong root tạm, cùng verifier cho sản phẩm đóng gói: executable, runtime file list, version, icon, chữ ký, entitlement và không kèm dữ liệu cá nhân. Có thể bắt đầu bằng CI macOS cho đúng nền tảng hiện tại; không cần ma trận ba hệ điều hành.

Đây là khả năng quan sát từ source CI, chưa phải kết luận workflow gần nhất đang xanh. Checksum tải cùng nơi với artifact giúp phát hiện sai/hỏng artifact nhưng không tự tạo nguồn xác thực độc lập.

Nguồn: [bridge contract tests](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/bridge_contract_tests.rs), [CI](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/.github/workflows/ci.yml), [release verifier](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/scripts/verify-release.mjs).

### E. Capability theo công cụ và nhóm profile — ưu tiên sau

AI Switch có registry công cụ và capability về auth method, credential backend, state mode. Profile set ánh xạ từng tool sang profile; có thêm workspace binding và guard mode.

Harbor có thể học cách mô tả capability khi preset hoặc provider tăng lên, thay vì rải điều kiện theo `kind`. Nhóm sync có tên cũng có ích khi người dùng quản lý nhiều ngữ cảnh công việc, nhưng phải giữ quyền chia sẻ lịch sử tường minh theo nguồn/đích. Không tự động đồng bộ chỉ vì hai profile nằm chung một nhóm khởi chạy.

Nguồn: [tool-registry.ts](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src/lib/tool-registry.ts), [profile-capabilities.ts](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src/features/shared/profile-capabilities.ts).

## 5. Những phần Harbor đã có và nên giữ

- `sync_transaction.py`: journal ghi trước, backup, kiểm tra hash trước rollback, recovery có thể chạy lại.
- `safe_io.py`: atomic replace, fsync file/thư mục, kiểm tra containment/symlink và nguồn thay đổi khi đọc.
- `desktop_launcher.py` và backend: lease/khóa file bảo vệ giữa các process.
- `bootstrap.py`: publish bộ runtime theo hash generation và đổi pointer atomically.
- `AccountManager.swift`: đọc stdout/stderr đồng thời, giới hạn output, timeout và terminate/kill backend.
- `profile_health.py`: phát hiện clone không còn phù hợp; `manager.py` có repair/recover.

Đây là kiểm chứng các cơ chế đang có trong source, không phải khẳng định đã audit đầy đủ tính an toàn của Harbor.

## 6. Những điểm không nên sao chép nguyên trạng

1. **Redaction còn hẹp.** `redaction.rs` nhận tiền tố `sk-` và `AIza`, rồi che đến whitespace. Chưa thấy xử lý tổng quát theo trường cho bearer token, cookie, email, đường dẫn cá nhân hoặc nội dung hội thoại. `diagnostic_bundle.rs` serialize JSON rồi mới lọc chuỗi; nếu phát triển tương tự nên lọc dữ liệu có cấu trúc trước serialize và kiểm tra JSON đầu ra. Nên xây bundle từ danh sách trường cho phép, dùng quyền file riêng tư của Harbor.
2. **Process thông thường chưa có giới hạn như Harbor.** Hàm `run_command` trong `bridge.rs` dùng `wait_with_output()`; tại hàm này không thấy timeout và giới hạn buffer. Không thay runner có giới hạn của Harbor bằng cách làm đơn giản hơn này.
3. **Auth/switching được ủy thác.** Repo desktop không đủ để chứng minh bảo đảm cô lập credential hoặc rollback của `aisw`. Các kết luận đó cần đọc runtime riêng và kiểm tra tương thích thật.
4. **Tauri tăng bề mặt phụ thuộc.** Capability/command allowlist là điểm hay của shell webview, nhưng Harbor có thể học nguyên tắc command tường minh bằng Swift/Python hiện tại.
5. **Cập nhật tự động là một hạng mục riêng.** Repo có updater, kiểm tra HTTPS và cấu hình public key. Áp dụng vào Harbor cần quy trình ký, notarize, rollback và kiểm tra runtime tương ứng; chưa nên bật chỉ để đạt ngang danh sách tính năng.

Nguồn: [redaction.rs](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/redaction.rs), [diagnostic_bundle.rs](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/diagnostic_bundle.rs), [bridge.rs](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/bridge.rs), [updater.rs](https://github.com/burakdede/aisw-desktop/blob/93bc5c0b9a579268183b8d42e5cb9a86b83eccb2/src-tauri/src/updater.rs).

## 7. Thứ tự áp dụng đề xuất

| Thứ tự | Hạng mục | Lý do | Bằng chứng cần có khi triển khai |
|---|---|---|---|
| 1 | Protocol version, capabilities, structured errors | UI và runtime hiểu nhau, lỗi có hướng xử lý | Contract test success/error/incompatible/malformed payload |
| 2 | Trạng thái thao tác thống nhất, kết quả và sức khỏe từng profile | Người dùng biết đang chờ gì, cần làm gì | Kiểm tra tray/window, lỗi sync/mở lại, hủy khi chờ |
| 3 | Release verifier và CI macOS | Chặn thiếu file runtime và sai bundle trước phát hành | Build trong môi trường sạch, kiểm tra bundle/ZIP/signature |
| 4 | Báo cáo chẩn đoán tối thiểu và lịch sử thao tác | Hỗ trợ điều tra mà giảm dữ liệu phải chia sẻ | Allowlist trường, quyền riêng tư, parse lại JSON, fixture secret |
| 5 | Nhóm sync có tên, tìm/mở profile bằng bàn phím | Tiện dụng khi số profile tăng | Xác minh phạm vi chia sẻ vẫn tường minh |

Các mục này là hướng phát triển để thảo luận và thiết kế tiếp, chưa phải thay đổi đã triển khai. Nghiên cứu chỉ thêm tài liệu này.
