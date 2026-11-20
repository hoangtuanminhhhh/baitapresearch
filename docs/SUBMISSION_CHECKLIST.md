# Checklist Hồ sơ Nộp bài & Chuẩn hóa Dự án (Thành viên 6)
**Đề tài:** Khảo sát ảnh hưởng của số lượng Client đồng thời đến hiệu năng TCP Server  
**Vai trò phụ trách:** TV6 — Technical Writer & Packaging Lead

---

## 1. Kiểm tra Cấu trúc Thư mục Chuẩn (Mục 5 Đề bài)

| Thành phần | Đường dẫn | Trạng thái chuẩn hóa | Ghi chú |
| :--- | :--- | :---: | :--- |
| **Hướng dẫn chạy** | `README.md` | [x] Hoàn thành | Hướng dẫn chạy & tái tạo thí nghiệm (TV6) |
| **Server Prototype** | `src/main/java/com/research/server/` | [x] Hoàn thành | Mã nguồn TCP Server đa luồng (TV1) |
| **Load Generator** | `src/load-generator/` | [x] Hoàn thành | Mã nguồn tạo tải & đo lường (TV2) |
| **Giao thức chung**| `docs/protocol.md` | [x] Hoàn thành | Đặc tả Frame nhị phân 1036 bytes (TV1) |
| **Cấu hình đo** | `experiments/configs/` | [x] Chuẩn hóa | File cấu hình JSON (TV3) |
| **Dữ liệu thô** | `experiments/raw-data/` | [x] Chuẩn hóa | Dữ liệu CSV/JSON đo đạc thực tế (TV3) |
| **Script phân tích**| `experiments/analysis/`| [x] Chuẩn hóa | Script Python phân tích số liệu (TV4) |
| **Biểu đồ kết quả** | `experiments/figures/` | [x] Chuẩn hóa | 3 biểu đồ độ phân giải cao PNG (TV4) |
| **Tài liệu & Báo cáo**| `docs/` | [x] Chuẩn hóa | Báo cáo PDF (TV5 & TV6) |

---

## 2. Kiểm tra Danh mục Hồ sơ Nộp bài (Deliverables)

1. [ ] **Báo cáo PDF (`docs/REPORT.pdf`):**
   - Độ dài: 4–6 trang nội dung chính (không tính bìa, phụ lục, tài liệu tham khảo).
   - Nội dung nghiên cứu: Câu hỏi, phạm vi, cơ sở lý thuyết, kiến trúc/protocol, phương pháp đo, kết quả, phân tích, giới hạn, kết luận.
   - Bảng phân chia công việc & tỷ lệ % đóng góp của từng thành viên.
   - Trích dẫn tối thiểu 3 tài liệu tham khảo chuẩn (IEEE).
   - Khai báo công cụ AI (nếu có sử dụng).
2. [x] **Mã nguồn hoàn chỉnh (Đã kiểm chứng biên dịch thành công):**
   - TCP Server (`src/main/java/com/research/server/` - TV1)
   - Load Generator (`src/load-generator/` - TV2)
   - Protocol chung (`src/main/java/com/research/common/Protocol.java` - TV1)
3. [x] **README.md:**
   - Đầy đủ thông số, lệnh biên dịch và tái lập thí nghiệm chỉ với 1–2 lệnh.
4. [ ] **Dữ liệu thực nghiệm & Biểu đồ:**
   - Dữ liệu thô trong `experiments/raw-data/` (đo tối thiểu 3 mức: 1, 10, 50 Clients, mỗi mức lặp lại 3 lần).
   - Tối thiểu 2 biểu đồ (khuyến nghị 3 biểu đồ: Throughput, Latency & Tail Latency p95, CPU Usage) trong `experiments/figures/`.
   - Script phân tích dữ liệu trong `experiments/analysis/`.
5. [ ] **Slide / Video trình bày:**
   - Slide thuyết trình hoặc video ngắn theo yêu cầu của học phần.
6. [x] **File `.gitignore` và Dọn sạch rác:**
   - Loại trừ hoàn toàn `target/`, `bin/`, `out/`, `.idea/`, `.vscode/`, `__pycache__/`, `*.class`.

---

## 3. Lưu ý Quan trọng về Quy mô Nhóm

> [!WARNING]
> Đề bài gốc quy định **5 sinh viên/nhóm**, nhưng nhóm hiện có **6 thành viên (TV1 – TV6)**.
> **Thành viên 6** cần nhắc Trưởng nhóm (TV1) xác nhận lại với Giảng viên phụ trách về sĩ số 6 sinh viên để bảng phân công đóng góp trong `REPORT.pdf` hoàn toàn hợp lệ trước khi nộp.

---

## 4. Hướng dẫn Đóng gói Nộp bài

Trước khi nộp bài, đảm bảo repository hoàn toàn sạch các file rác biên dịch và cache. Sử dụng một trong hai cách sau:

**Cách 1: Sử dụng Git Archive (Khuyến nghị)**
```bash
git archive --format=zip --output="submission_tcp_server_benchmark.zip" HEAD
```

**Cách 2: Sử dụng PowerShell nén các thư mục quy định**
```powershell
Compress-Archive -Path README.md, pom.xml, src, experiments, docs -DestinationPath submission_tcp_server_benchmark.zip -Force
```
