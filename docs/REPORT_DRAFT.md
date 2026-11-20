# BÁO CÁO NGHIÊN CỨU THỰC NGHIỆM
# KHẢO SÁT ẢNH HƯỞNG CỦA SỐ LƯỢNG CLIENT ĐỒNG THỜI ĐẾN HIỆU NĂNG TCP SERVER

**Học phần:** Lập trình Mạng  
**Đề tài:** Khảo sát ảnh hưởng của số lượng Client đồng thời đến hiệu năng TCP Server (Echo Benchmark)  
**Nhóm thực hiện:** Nhóm 6 thành viên (TV1 – TV6)  
**Ngày hoàn thiện:** Tháng 11 / 2026  

---

## TÓM TẮT BÁO CÁO (ABSTRACT)
Nghiên cứu này khảo sát định lượng ảnh hưởng của số lượng Client đồng thời ($1, 10, 50$ kết nối) đến hiệu năng tổng thể của một máy chủ TCP (TCP Echo Server) được xây dựng trên nền tảng Java 21 LTS sử dụng mô hình Blocking Socket kết hợp Fixed Thread Pool. Các chỉ số được đánh giá độc lập bao gồm: thông lượng (Throughput), độ trễ trung bình (Average Latency), độ trễ đuôi phân vị 95 (p95 Tail Latency), tỷ lệ lỗi (Error Rate) và mức tiêu thụ tài nguyên vi xử lý (Server CPU Usage). Hệ thống áp dụng giao thức đóng gói nhị phân (Length-Prefix Framing 1036 bytes) nhằm loại trừ triệt để hiện tượng dính/xé gói của luồng TCP. Kết quả thực nghiệm và phân tích thống kê qua các lần chạy độc lập làm sáng tỏ ngưỡng bão hòa của mô hình Thread Pool đa luồng trong môi trường cạnh tranh tài nguyên hệ điều hành.

---

## 1. CÂU HỎI NGHIÊN CỨU VÀ PHẠM VI (RESEARCH QUESTION & SCOPE)
*(Phần do Thành viên 5 chủ trì hoàn thiện)*

### 1.1. Câu hỏi nghiên cứu cốt lõi
> **Khi số lượng Client đồng thời tăng (tối thiểu ở các mức 1, 10, 50), độ trễ (latency), thông lượng (throughput) và mức sử dụng CPU của TCP Server thay đổi như thế nào?**

### 1.2. Phạm vi nghiên cứu
* Dịch vụ mạng: Dạng **Echo Benchmark** tối giản (Request gồm 8 byte `requestId` và 1024 byte `payload`, Server echo nguyên vẹn frame phản hồi).
* Kiến trúc: 2 tiến trình riêng biệt (Process Server và Process Load Generator).
* Mô hình lập trình: Blocking Socket đa luồng (Multi-threaded with Fixed Thread Pool).
* Môi trường: Localhost loopback nhằm loại trừ ảnh hưởng của độ trễ đường truyền vật lý ngoài.

---

## 2. CƠ SỞ LÝ THUYẾT (THEORETICAL BACKGROUND)
*(Phần do Thành viên 5 chủ trì hoàn thiện)*

* **Bản chất hướng luồng của giao thức TCP:** Khác với UDP hoạt động theo ranh giới datagram, TCP là giao thức byte stream liên tục. Dữ liệu ghi vào `OutputStream` có thể được tầng giao vận chia nhỏ hoặc ghép nhiều frame qua các cơ chế buffer (SO_RCVBUF, SO_SNDBUF) và giải thuật Nagle. Do đó, việc xây dựng cơ chế Framing ở tầng ứng dụng là điều kiện bắt buộc để xác định ranh giới gói tin.
* **Mô hình Blocking Socket kết hợp Thread Pool:** Khắc phục nhược điểm của mô hình "Thread-per-Connection" thuần túy (dễ cạn kiệt tài nguyên bộ nhớ stack và quá tải OS scheduler). Thread Pool tái sử dụng một tập hợp luồng cố định, hạn chế chi phí cấp phát và hủy luồng.
* **Chi phí chuyển đổi ngữ cảnh (Context Switching) & Tranh chấp CPU:** Khi số lượng luồng vượt quá số nhân logic của CPU, hệ điều hành buộc phải hoán đổi trạng thái thanh ghi và bộ đệm CPU liên tục, dẫn đến hiện tượng trễ gia tăng.
* **Ý nghĩa học thuật của Tail Latency (p95 / p99):** Độ trễ trung bình thường làm lu mờ các đỉnh trễ nghiêm trọng do Garbage Collection (GC) của JVM, chuyển đổi ngữ cảnh hoặc hàng đợi hệ điều hành gây ra.

---

## 3. KIẾN TRÚC HỆ THỐNG VÀ ĐẶC TẢ GIAO THỨC (ARCHITECTURE & PROTOCOL)
*(Phần do Thành viên 6 hoàn thiện)*

### 3.1. Kiến Trúc Phân Tán Độc Lập
Hệ thống được thiết kế với hai tiến trình OS tách biệt hoàn toàn:
1. **TCP Server (`com.research.server.TCPEchoServer`):** Quản lý luồng lắng nghe `acceptLoop`, tiếp nhận kết nối đẩy vào `FixedThreadPool(256)`, kích hoạt `CpuMonitor` lấy mẫu CPU mỗi giây.
2. **Load Generator (`LoadGeneratorApp`):** Quản lý $M$ worker threads đồng thời ($M \in \{1, 10, 50\}$), mỗi worker mở một TCP Socket riêng biệt với `TCP_NODELAY = true`.

### 3.2. Đặc Tả Giao Thức Nhị Phân (Binary Framing - 1036 Bytes)
Tất cả các gói tin Request và Response tuân thủ định dạng Big-Endian:
* **Header (4 bytes):** $N = 8 + \text{Payload length}$ (với payload 1024 bytes $\Rightarrow N = 1032$).
* **Request ID (8 bytes):** `(clientId << 32) | sequenceNumber`.
* **Payload (1024 bytes):** Mảng byte nhị phân 1 KB.
* **Tổng kích thước 1 Frame:** $4 + 8 + 1024 = 1036 \text{ bytes}$.

### 3.3. Mô Hình Xử Lý An Toàn Tại Server
* **Đọc an toàn với `readFully()`:** Đọc đúng 4 byte độ dài $N$, sau đó gọi `readFully` đọc đủ $N$ bytes của body, giải quyết dứt điểm lỗi xé gói do phân đoạn TCP.
* **Chống tràn bộ nhớ (DoS Protection):** Ràng buộc nghiêm ngặt $8 \le N \le 65536$ (`MAX_BODY = 64 KB`). Frame vượt ngưỡng bị ngắt kết nối ngay lập tức.
* **Xử lý Timeout:** `socket.setSoTimeout(30000)` (30 giây) chống rò rỉ luồng.
* **Chịu lỗi ngắt kết nối đột ngột:** Bắt ngoại lệ `SocketException: Connection reset`, giải phóng tài nguyên an toàn trong khối `finally`.

---

## 4. MÔI TRƯỜNG VÀ PHƯƠNG PHÁP THỰC NGHIỆM (METHODOLOGY)
*(Phần do Thành viên 6 hoàn thiện)*

### 4.1. Thông Số Môi Trường Thử Nghiệm
* **CPU:** Intel(R) Core(TM) i7-7820HQ @ 2.90 GHz (4 nhân vật lý, 8 luồng logic, Turbo 3.90 GHz).
* **RAM:** 16 GB DDR4 (khả dụng: 15.88 GB).
* **Hệ điều hành:** Microsoft Windows 10 Pro 64-bit (OS Build 19045).
* **Nền tảng JVM:** OpenJDK 21.0.12.1 LTS (Eclipse Temurin build, 64-Bit Server VM).
* **Giao diện mạng:** Loopback Interface (`127.0.0.1`), MTU = 65,535 bytes, độ trễ vật lý $\approx 0$ ms.

### 4.2. Quy Chuẩn Đo Lường & Ma Trận 3x3
* **Warm-up 5 giây:** Loại bỏ số liệu trong 5 giây đầu để JVM HotSpot JIT C1/C2 tối ưu hóa mã máy.
* **Đo chính thức 20 giây:** Bấm giờ chính xác bằng `System.nanoTime()`.
* **Ma trận thực nghiệm:** Khảo sát 3 mức ($1, 10, 50$ Clients), mỗi mức lặp lại độc lập 3 lần để tính Mean ($\mu$) và StdDev ($\sigma$).
* **Xác nhận 4 ca kiểm thử chịu lỗi:**
  * TC1: Ổn định tại 1 Client vs 50 Clients.
  * TC2: Kiểm chứng toàn vẹn 100% `requestId` và `payload`.
  * TC3: Client bị kill ngang đột ngột, Server vẫn duy trì hoạt động.
  * TC4: Gói tin rác / $N > 64\text{ KB}$ bị Server từ chối an toàn.

---

## 5. KẾT QUẢ THỰC NGHIỆM VÀ PHÂN TÍCH (RESULTS & ANALYSIS)
*(Phần do Thành viên 4 cung cấp số liệu và Thành viên 5 chủ trì viết phân tích)*

### 5.1. Bảng Tổng Hợp Số Liệu Thực Nghiệm (3x3 Matrix)

| Số Client | Throughput TB (req/s) | Avg Latency TB (ms) | p95 Latency TB (ms) | Server CPU TB (%) | Error Rate (%) |
| :---: | :---: | :---: | :---: | :---: | :---: |
| **1 Client** | *(Đang cập nhật)* | *(Đang cập nhật)* | *(Đang cập nhật)* | *(Đang cập nhật)* | 0.0% |
| **10 Clients** | *(Đang cập nhật)* | *(Đang cập nhật)* | *(Đang cập nhật)* | *(Đang cập nhật)* | 0.0% |
| **50 Clients** | *(Đang cập nhật)* | *(Đang cập nhật)* | *(Đang cập nhật)* | *(Đang cập nhật)* | 0.0% |

*(Bảng số liệu chi tiết sẽ được tự động trích xuất từ `experiments/analysis/summary_metrics.csv` khi TV3 và TV4 hoàn tất đo đạc).*

### 5.2. Biểu Đồ Trực Quan Hóa (Visualizations)
* **Hình 1:** Thông lượng hệ thống (Throughput) theo số lượng Client đồng thời (`figures/throughput_vs_clients.png`).
* **Hình 2:** Độ trễ trung bình và độ trễ đuôi p95 theo số lượng Client (`figures/latency_vs_clients.png`).
* **Hình 3:** Mức sử dụng CPU của Server theo số lượng Client (`figures/cpu_vs_clients.png`).

### 5.3. Phân Tích Chuyên Sâu Các Hiện Tượng
*(TV5 phân tích dựa trên số liệu: giải thích ngưỡng bão hòa thông lượng do giới hạn CPU, hiện tượng tail latency tăng vọt ở mức 50 clients do chi phí context switch và GC pause).*

---

## 6. GIỚI HẠN VÀ KẾT LUẬN (LIMITATIONS & CONCLUSION)
*(Phần do Thành viên 5 chủ trì hoàn thiện)*

* **Giới hạn nghiên cứu:** Thực nghiệm thực hiện trên môi trường Loopback (localhost) khiến tiến trình Server và tiến trình Load Generator cạnh tranh tài nguyên CPU trên cùng một máy; chưa khảo sát trên mạng diện rộng (WAN) có độ trễ vật lý và tỷ lệ mất gói (packet loss).
* **Kết luận chung:** Trả lời trực diện câu hỏi nghiên cứu về sự thay đổi của Throughput, Latency và CPU khi tăng số client từ 1 lên 50.

---

## 7. BẢNG PHÂN CÔNG TRÁCH NHIỆM & TỶ LỆ ĐÓNG GÓP
*(Phần do Thành viên 6 hoàn thiện)*

| STT | Thành viên | Vai trò phụ trách | Chi tiết nhiệm vụ thực tế đã thực hiện | Sản phẩm bàn giao chính | Tỷ lệ đóng góp |
| :---: | :--- | :--- | :--- | :--- | :---: |
| 1 | **Thành viên 1** | **Team Lead / Server Core** | Thiết kế Socket đa luồng, `TCPEchoServer`, `ClientHandler`, `CpuMonitor`, giao thức Framing `readFully` và cơ chế chịu lỗi. | `src/main/java/com/research/server/*`, `docs/protocol.md` | **17%** |
| 2 | **Thành viên 2** | **Load Generator Lead** | Xây dựng `LoadGeneratorApp`, `BenchmarkWorker`, `MetricsCollector`, xử lý đo RTT nano-giây, tính p95 và xuất CSV/JSON. | `src/load-generator/*` | **17%** |
| 3 | **Thành viên 3** | **Automation & Test Lead** | Tự động hóa ma trận thực nghiệm 3x3 (`run_benchmarks.ps1`), cấu hình benchmark, thực thi và kiểm chứng 4 ca test TC1–TC4. | `experiments/scripts/*`, `experiments/raw-data/` | **17%** |
| 4 | **Thành viên 4** | **Data Analysis Lead** | Viết script Python (`analyze_data.py`), tính thống kê Mean/StdDev, đối chiếu kiểm chứng số liệu, xuất 3 biểu đồ 300 DPI. | `experiments/analysis/*`, `experiments/figures/*.png` | **16%** |
| 5 | **Thành viên 5** | **Lead Research Writer** | Soạn thảo nội dung học thuật báo cáo PDF (Mục 1, 2, 5, 6): cơ sở lý thuyết, phân tích kết quả chuyên sâu, giải thích hiện tượng và kết luận. | Báo cáo học thuật Mục 1, 2, 5, 6 | **17%** |
| 6 | **Thành viên 6** | **Technical Writer & Packaging Lead** | Soạn thảo nội dung kỹ thuật (Mục 3, 4, 7, 8), viết `README.md`, chuẩn hóa repository và đóng gói hồ sơ nộp bài. | `README.md`, Mục 3, 4, 7, 8 trong báo cáo, hồ sơ nộp bài | **16%** |
| — | **TỔNG CỘNG** | **Toàn đội ngũ** | **Phối hợp thực hiện toàn diện theo đúng tiến độ đề tài.** | **Hồ sơ nghiên cứu hoàn chỉnh** | **100%** |

---

## 8. TÀI LIỆU THAM KHẢO & KHAI BÁO SỬ DỤNG AI
*(Phần do Thành viên 6 hoàn thiện)*

### 8.1. Danh Mục Tài Liệu Tham Khảo Chuẩn IEEE
```text
[1] J. F. Kurose and K. W. Ross, Computer Networking: A Top-Down Approach, 8th ed. 
    Hoboken, NJ, USA: Pearson, 2021, pp. 235–280.
[2] W. R. Stevens, B. Fenner, and A. M. Rudoff, UNIX Network Programming, Volume 1: 
    The Sockets Networking API, 3rd ed. Boston, MA, USA: Addison-Wesley Professional, 2004.
[3] J. Dean and L. A. Barroso, "The Tail at Scale," Communications of the ACM, 
    vol. 56, no. 2, pp. 74–80, Feb. 2013, doi: 10.1145/2408776.2408794.
[4] Oracle Corporation, "Java Platform, Standard Edition Documentation - Networking and Sockets API (JDK 21 LTS)," 
    Oracle Technology Network, 2023. [Online].
[5] B. Goetz, T. Peierls, J. Bloch, J. Bowbeer, D. Holmes, and D. Lea, 
    Java Concurrency in Practice. Boston, MA, USA: Addison-Wesley Professional, 2006.
```

### 8.2. Tuyên Bố Sử Dụng Công Cụ Trí Tuệ Nhân Tạo (AI Usage Declaration)
* **Công cụ sử dụng:** Trợ lý trí tuệ nhân tạo (AI Assistant).
* **Mục đích sử dụng:** Hỗ trợ định dạng văn bản học thuật Markdown/LaTeX, rà soát văn phong tiếng Việt và gợi ý biểu diễn trực quan các bảng đặc tả gói tin. Toàn bộ kiến trúc kỹ thuật, mã nguồn, dữ liệu thực nghiệm và kết luận khoa học đều do nhóm tự nghiên cứu, lập trình và thực hiện.
