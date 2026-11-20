# BÁO CÁO NGHIÊN CỨU KHOA HỌC: HIỆU NĂNG TCP SERVER
## PHẦN KỸ THUẬT: MỤC 3, 4, 7, 8 (DO THÀNH VIÊN 6 ĐẢM NHIỆM)

---

## MỤC 3: KIẾN TRÚC HỆ THỐNG VÀ ĐẶC TẢ GIAO THỨC (ARCHITECTURE & PROTOCOL)

### 3.1. Kiến Trúc Tổng Thể Hệ Thống (System Architecture)

Hệ thống khảo sát thực nghiệm được xây dựng theo mô hình **Request/Response Client-Server** phân tán tối giản (Echo Benchmark), đảm bảo nguyên tắc tách biệt hoàn toàn giữa tiến trình máy chủ và tiến trình tạo tải:

```text
+-----------------------------------------------------------------------------------+
|                            HỆ THỐNG THỰC NGHIỆM ĐO TẢI TCP                        |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [ TIẾN TRÌNH 2: LOAD GENERATOR ]                     [ TIẾN TRÌNH 1: TCP SERVER ]|
|  (LoadGeneratorApp - PID B)                           (TCPEchoServer - PID A)     |
|                                                                                   |
|  +------------------------------+                     +-------------------------+ |
|  |       ExecutorService        |                     |      ServerSocket       | |
|  |     (Thread Pool Worker)     |                     |    (Bind: Port 8080)    | |
|  |  [Worker 1]  ...  [Worker M] |                     |    (Backlog Queue: 256) | |
|  +------+----------------+------+                     +------------+------------+ |
|         |                |                                         |              |
|         | Socket(1)      | Socket(M)                     accept()  | Loop         |
|         |                |                                         v              |
|         |                |                     +-------------------------+        |
|         |                |                     |     ExecutorService     |        |
|         |                |                     |  (FixedThreadPool: 256) |        |
|         |                |                     | [Handler 1] ... [Hdl M] |        |
|         |                |                     +------------+------------+        |
|         |                |                                  |                     |
|         v                v                                  v                     |
|   +----------------------------+                     +--------------------------+ |
|   |   HỆ ĐIỀU HÀNH (OS STACK)  |<===================>|  CpuMonitor (Luồng nền)  | |
|   |  - Loopback TCP (127.0.0.1)|     1036-Byte       |  - 1s/lần lấy mẫu CPU    | |
|   |  - TCP_NODELAY: Enabled    |     Binary Frame    |  - OperatingSystemMXBean | |
|   |  - SO_RCVBUF / SO_SNDBUF   |                     +--------------------------+ |
|   +----------------------------+                                                  |
+-----------------------------------------------------------------------------------+
```

#### Các thành phần chính trong kiến trúc:
1. **Tiến trình TCP Server (`com.research.server.TCPEchoServer`):**
   * Lắng nghe trên địa chỉ `0.0.0.0` hoặc `127.0.0.1` tại cổng dịch vụ (mặc định `8080` hoặc `9000`).
   * Sử dụng hàng đợi chấp nhận kết nối `backlog = 256` để chống nghẽn kết nối bước đầu khi nhiều client đồng thời kết nối.
   * Khởi chạy một luồng nền độc lập `CpuMonitor` ghi nhận mức tiêu thụ CPU của tiến trình Server theo chu kỳ 1 giây/lần.
2. **Tiến trình Tạo Tải Độc Lập (`LoadGeneratorApp`):**
   * Chạy ở một không gian bộ nhớ và tiến trình OS hoàn toàn riêng biệt.
   * Quản lý $M$ luồng (`BenchmarkWorker`) độc lập thông qua `ExecutorService` tương ứng với số lượng Client đồng thời ($M \in \{1, 10, 50\}$).
   * Mỗi Client logic tự mở một kết nối TCP riêng biệt (`java.net.Socket`), duy trì kết nối liên tục (persistent connection) trong suốt phiên đo để phản ánh đúng áp lực tải đồng thời.
   * Kích hoạt cờ `TCP_NODELAY = true` nhằm vô hiệu hóa giải thuật Nagle, loại bỏ độ trễ gom gói tin nhân tạo của tầng giao vận và bảo đảm đo lường chính xác Round Trip Time (RTT).

---

### 3.2. Đặc Tả Giao Thức Nhị Phân (Binary Framing Protocol)

#### 3.2.1. Vấn đề của TCP Stream và Giải pháp Framing
TCP là giao thức hướng luồng (stream-oriented), truyền tải dữ liệu dưới dạng một chuỗi byte liên tục không có ranh giới phân tách thông điệp (message boundary). Trong môi trường tải cao, việc gọi hàm `read()`/`Receive()` của socket có thể gặp hai hiện tượng vật lý tất yếu:
* **Dính gói (Coalescing / Packet Pasting):** Nhiều request gửi liên tiếp bị gộp chung vào một bộ đệm nhận duy nhất.
* **Xé gói (Fragmentation):** Một request lớn bị chia cắt thành nhiều mẩu byte rời rạc qua các phân đoạn TCP Segment.

Để giải quyết triệt để vấn đề này, nhóm thiết kế giao thức nhị phân theo cơ chế **Tiền tố độ dài (Length-Prefix Framing)**.

#### 3.2.2. Cấu trúc Frame Chuẩn (1036 Bytes)
Tất cả các gói tin Request và Response đều có cấu trúc đối xứng cố định, tuân thủ thứ tự byte **Big-Endian** (Network Byte Order):

```text
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Body Length (N)                         |  Offset 0..3 (4 bytes)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |  Offset 4..11 (8 bytes)
|                        Request ID (long)                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |  Offset 12..N+3
|                     Payload Data (N - 8 bytes)               |  (1024 bytes)
|                             ...                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Trường dữ liệu (Field) | Kích thước | Kiểu dữ liệu | Offset | Ý nghĩa và Mô tả kỹ thuật |
| :--- | :---: | :---: | :---: | :--- |
| **Body Length ($N$)** | 4 bytes | `int32` (Big-Endian) | `0 – 3` | Xác định độ dài chính xác của phần thân message ($N = 8 + \text{Payload length}$). Với payload 1024 bytes, $N = 1032$. |
| **Request ID** | 8 bytes | `int64` (Big-Endian) | `4 – 11` | Định danh tuần tự của request, được ghép bit: `(clientId << 32) | sequenceNumber`. Giúp đối chiếu response trả về có chính xác với request đã gửi hay không. |
| **Payload Data** | $N - 8$ bytes | `byte[]` nhị phân | `12 – (N+3)` | Mảng dữ liệu nội dung thí nghiệm. Trong thực nghiệm chuẩn có kích thước cố định là **1024 bytes (1 KB)**. |
| **Tổng Frame chuẩn** | **1036 bytes** | Khung nhị phân | — | $4 \text{ bytes Header} + 1032 \text{ bytes Body} = 1036 \text{ bytes}$. |

---

### 3.3. Mô Hình Xử Lý Đa Luồng & Cơ Chế Chịu Lỗi Tại Server

Lớp `ClientHandler` chạy trong tiến trình `TCPEchoServer` được thiết kế theo mô hình hướng luồng an toàn (robust multi-threading):

1. **Mô hình Thread Pool cố định (Fixed Thread Pool):**
   * Server sử dụng `Executors.newFixedThreadPool(poolSize)` với `poolSize = 256`. 
   * Cấu hình này bảo đảm đủ số worker luân chuyển phục vụ đồng thời tối đa 50 clients mà không bị dồn ứ tác vụ trong hàng đợi nội bộ (`LinkedBlockingQueue`), hạn chế tối đa độ trễ hàng đợi (queuing delay) không mong muốn.
2. **Cơ chế đọc an toàn với `DataInputStream.readFully()`:**
   * Thay vì gọi `InputStream.read()` thông thường, Server đọc chính xác 4 byte đầu tiên để lấy giá trị $N$ thông qua `readInt()`.
   * Tiếp đó, Server dùng phương thức `readFully(byte[] b, int off, int len)` để block và đọc đúng $N$ bytes của thân body. Phương thức này bảo đảm dữ liệu chỉ được xử lý khi đã nạp trọn vẹn toàn bộ frame, giải quyết dứt điểm lỗi xé gói do phân đoạn TCP.
3. **Phản hồi dữ liệu đối xứng (Atomic Echo Response):**
   * Server giữ nguyên cấu trúc frame nhận được, ghi lại 4 byte $N$ cùng mảng body vào `DataOutputStream` và lập tức gọi `out.flush()` để đẩy gói tin ra luồng mạng ngay lập tức.
4. **Cơ chế Chịu Lỗi & Phòng Vệ Tài Nguyên (Fault-Tolerance & Resource Safety):**
   * **Chống tấn công tràn bộ nhớ (OOM / DoS Protection):** Server kiểm tra nghiêm ngặt điều kiện:
     $$8 \le N \le 65536 \quad (\text{với } \text{MAX\_BODY} = 64\text{ KB})$$
     Nếu client gửi $N < 8$ hoặc $N > 65536$, Server lập tức coi đây là vi phạm giao thức, tăng biến đếm `protocolErrors` và đóng kết nối ngay lập tức mà không cấp phát mảng byte rác.
   * **Xử lý Timeout (`SO_TIMEOUT`):** Thiết lập `socket.setSoTimeout(30000)` (30 giây). Nếu client không gửi dữ liệu quá thời gian này, ngoại lệ `SocketTimeoutException` được kích hoạt và đóng socket để tránh rò rỉ tài nguyên luồng (thread starvation).
   * **Chịu lỗi ngắt kết nối đột ngột (Abrupt Disconnect Handling):** Khi client bị tắt đột ngột (crash/kill process), tầng TCP sinh lỗi `SocketException: Connection reset`. Khối `try-catch` cục bộ bắt lỗi, tăng biến đếm `abruptDisconnects` và thực thi khối `finally { socket.close(); }`, tuyệt đối không làm ảnh hưởng đến luồng Server chính hay các client khác đang kết nối.

---

## MỤC 4: MÔI TRƯỜNG VÀ PHƯƠNG PHÁP THỰC NGHIỆM (METHODOLOGY)

### 4.1. Thông Số Môi Trường Thử Nghiệm (Testbed Specification)

Thực nghiệm được tiến hành trên một môi trường phần cứng và phần mềm đồng nhất, kiểm soát chặt chẽ các tác vụ nền:

| Thành phần hệ thống | Thông số chi tiết cấu hình thực nghiệm |
| :--- | :--- |
| **Bộ vi xử lý (CPU)** | **Intel(R) Core(TM) i7-7820HQ** @ 2.90 GHz (4 nhân vật lý, 8 luồng xử lý / Logical Processors, Turbo Boost tối đa 3.90 GHz, 8 MB SmartCache). |
| **Bộ nhớ trong (RAM)** | **16.0 GB DDR4** Bus 2400 MHz (dung lượng khả dụng thực tế: 15.88 GB). |
| **Hệ điều hành (OS)** | **Microsoft Windows 10 Pro 64-bit** (Version 22H2, OS Build 19045). |
| **Nền tảng Java (JVM)** | **OpenJDK 21.0.12.1 LTS** (Eclipse Temurin build 21.0.12.1+1-LTS, 64-Bit Server VM, Mixed Mode, Tiered Compilation). |
| **Giao diện mạng đo** | **Loopback Interface (`127.0.0.1`)**, MTU = 65,535 bytes. Giao thức TCP/IP cục bộ với độ trễ đường truyền vật lý xấp xỉ 0 ms, loại trừ triệt để nhiễu suy hao từ switch/router ngoài. |
| **Tham số JVM** | `-Duser.language=en -Duser.country=US -Xms512m -Xmx2048m` |

---

### 4.2. Phương Pháp Đo Lường & Quy Trình Thực Nghiệm

#### 4.2.1. Phân kỳ Đo lường (Warm-up và Official Measurement)
Mỗi đợt chạy thực nghiệm được chia làm 2 giai đoạn nối tiếp:
1. **Giai đoạn Làm nóng (Warm-up - 5 giây):** 
   * Cho phép các Client gửi/nhận request liên tục nhưng toàn bộ dữ liệu RTT phát sinh trong 5 giây này đều bị hủy bỏ.
   * *Mục đích kỹ thuật:* Đảm bảo JVM JIT Compiler (Just-In-Time) thực hiện biên dịch bytecode thành mã máy tối ưu (HotSpot C1/C2 compilation), khởi tạo ổn định các luồng trong Thread Pool và kích hoạt cơ chế đệm của hệ điều hành trước khi bấm giờ chính thức.
2. **Giai đoạn Đo chính thức (Official Run - 20 giây):**
   * Kích hoạt cờ thu thập số liệu `collector.startRecording()`.
   * Mọi request hoàn tất trong 20 giây này đều được ghi nhận thời gian gửi/nhận, kiểm tra tính toàn vẹn và lưu trữ vào danh sách RTT.

#### 4.2.2. Ma trận Thực nghiệm (3x3 Experimental Matrix)
Khảo sát được thực hiện trên ma trận đầy đủ gồm **3 mức tải** $\times$ **3 lần lặp lại độc lập**:
* Các mức Client đồng thời: **`1 Client`**, **`10 Clients`**, **`50 Clients`**.
* Mỗi kịch bản cấu hình được chạy lặp lại đúng **3 lần (`Run 1`, `Run 2`, `Run 3`)** để tính giá trị trung bình đại diện ($\mu$) và độ lệch chuẩn ($\sigma$), qua đó đánh giá độ biến động (variance) của hệ thống.
* Giữa các đợt chạy có thời gian hạ nhiệt (cooldown 3 giây) và khởi động mới tiến trình Server để bảo đảm giải phóng hoàn toàn bộ nhớ heap và Garbage Collection.

#### 4.2.3. Thu thập Chỉ số Hiệu năng & Bấm giờ Độ phân giải cao
* Thời gian phản hồi RTT (Round Trip Time) được bấm giờ ở cấp độ nano-giây:
  $$\text{RTT} = \frac{\text{System.nanoTime}_{\text{recv}} - \text{System.nanoTime}_{\text{sent}}}{1\,000\,000.0} \quad (\text{ms})$$
* **Throughput (req/s):** Số lượng request thành công trong đúng 20 giây đo chính thức.
* **Average Latency (ms):** Trung bình cộng của toàn bộ mẫu RTT hợp lệ.
* **p95 Tail Latency (ms):** Sắp xếp toàn bộ mảng RTT theo thứ tự tăng dần, giá trị p95 là phần tử tại vị trí index: $\lceil 0.95 \times K \rceil - 1$.
* **Error Rate (%):** Tỷ lệ phần trăm giữa số request lỗi (sai lệch dữ liệu hoặc timeout) trên tổng số request gửi đi.
* **Mức sử dụng CPU (%):** Luồng `CpuMonitor` ghi lại tải CPU tiến trình mỗi giây một lần thông qua hàm `OperatingSystemMXBean.getProcessCpuLoad() * 100`.

---

### 4.3. Xác Minh 4 Ca Kiểm Thử Chịu Lỗi Bắt Buộc (Validation Test Cases)

Bộ kiểm thử tự động `experiments/scripts/run_validation_tests.ps1` kiểm chứng toàn diện 4 ca thử nghiệm theo đúng yêu cầu Mục 4 của Đề tài:

| Mã test | Tên ca kiểm thử | Điều kiện thực hiện & Kịch bản kích hoạt | Tiêu chí đạt (Pass Criteria) |
| :---: | :--- | :--- | :--- |
| **TC1** | **Tải đơn vs Tải cao** | So sánh hiệu năng giữa mức 1 Client và 50 Clients đồng thời trong điều kiện tải liên tục. | Hệ thống duy trì ổn định, Error Rate đạt 0.0%, Server không bị tràn luồng hay treo tiến trình. |
| **TC2** | **Kiểm chứng Toàn vẹn Dữ liệu** | Bắn tải đồng thời với các kích thước payload biên: 0B, 16B, 1KB, 32KB, 64KB và dữ liệu bị cắt nhỏ/phân mảnh. | 100% response nhận về có `requestId` và mảng byte `payload` khớp chính xác từng bit so với request (`Arrays.equals == true`). |
| **TC3** | **Chịu lỗi Ngắt kết nối Đột ngột** | Khi 50 client đang gửi dữ liệu tốc độ cao, cưỡng bức kill tiến trình Client bằng `taskkill /F` hoặc ngắt nửa chừng frame TCP RST. | Server ghi nhận sự kiện vào `abruptDisconnects`, giải phóng socket an toàn và sẵn sàng phục vụ client mới mà không bị sập. |
| **TC4** | **Xử lý Frame Dị tật / Vượt ngưỡng** | Gửi frame có chiều dài $N = 65537$ (> 64 KB), $N = 999999$ hoặc frame bị cắt cụt header (chỉ có 2 bytes). | Server phát hiện vi phạm giao thức, tăng `protocolErrors`, đóng socket vi phạm ngay lập tức, không gây treo CPU hay sập tiến trình. |

---

## MỤC 7: BẢNG PHÂN CÔNG TRÁCH NHIỆM & TỶ LỆ ĐÓNG GÓP (CONTRIBUTION TABLE)

Dự án được phân chia công việc chuyên trách rõ ràng giữa **6 thành viên**, đảm bảo mọi mắt xích từ kiến trúc mã nguồn, đo lường tự động, phân tích dữ liệu cho đến viết tài liệu học thuật đều có người chịu trách nhiệm chính:

| STT | Thành viên | Vai trò phụ trách | Chi tiết nhiệm vụ thực tế đã thực hiện | Sản phẩm bàn giao chính | Tỷ lệ đóng góp |
| :---: | :--- | :--- | :--- | :--- | :---: |
| 1 | **Thành viên 1** | **Team Lead / Server Core** | Thiết kế kiến trúc Socket đa luồng, lớp `TCPEchoServer`, `ClientHandler`, module đo CPU `CpuMonitor`, cơ chế framing `readFully` và chịu lỗi. | `src/main/java/com/research/server/*`, `docs/protocol.md` | **17%** |
| 2 | **Thành viên 2** | **Load Generator Lead** | Xây dựng ứng dụng tạo tải `LoadGeneratorApp`, `BenchmarkWorker`, `MetricsCollector`, xử lý bấm giờ nano-giây, phân vị RTT và xuất file CSV/JSON. | `src/load-generator/*` | **17%** |
| 3 | **Thành viên 3** | **Automation & Test Lead** | Tự động hóa ma trận thực nghiệm 3x3 (`run_benchmarks.ps1`), cấu hình `benchmark_config.json`, thực thi và xác nhận 4 ca kiểm thử chịu lỗi TC1–TC4. | `experiments/scripts/*`, `experiments/raw-data/` | **17%** |
| 4 | **Thành viên 4** | **Data Analysis Lead** | Viết script Python (`analyze_data.py`), tính toán thống kê Mean/StdDev, tổng hợp số liệu kiểm chứng, vẽ 3 biểu đồ chuẩn học thuật 300 DPI. | `experiments/analysis/*`, `experiments/figures/*.png` | **16%** |
| 5 | **Thành viên 5** | **Lead Research Writer** | Soạn thảo nội dung học thuật báo cáo PDF (Mục 1, 2, 5, 6): cơ sở lý thuyết TCP/Thread Pool, phân tích chuyên sâu kết quả thực nghiệm và kết luận. | Nội dung Mục 1, 2, 5, 6 trong `docs/REPORT.pdf` | **17%** |
| 6 | **Thành viên 6** | **Technical Writer & Packaging Lead** | Soạn thảo nội dung kỹ thuật báo cáo (Mục 3, 4, 7, 8), viết hướng dẫn `README.md`, chuẩn hóa repository và đóng gói hồ sơ nộp bài. | `README.md`, Mục 3, 4, 7, 8 trong báo cáo, hồ sơ đóng gói | **16%** |
| — | **TỔNG CỘNG** | **Toàn đội ngũ** | **Phối hợp thực hiện toàn diện theo đúng tiến độ 4 tuần đề ra.** | **Hồ sơ nghiên cứu hoàn chỉnh** | **100%** |

> [!NOTE]
> **Lưu ý về sĩ số nhóm:** Đề bài gốc quy định 5 sinh viên/nhóm. Nhóm triển khai thực tế gồm 6 thành viên (TV1 – TV6) với khối lượng công việc được chia đều chuyên sâu. Nhóm đã chủ động đối chiếu xác nhận sĩ số với Giảng viên phụ trách học phần.

---

## MỤC 8: TÀI LIỆU THAM KHẢO & KHAI BÁO SỬ DỤNG AI (REFERENCES & AI DECLARATION)

### 8.1. Danh Mục Tài Liệu Tham Khảo Chuẩn IEEE

```text
[1] J. F. Kurose and K. W. Ross, Computer Networking: A Top-Down Approach, 8th ed. 
    Hoboken, NJ, USA: Pearson, 2021, pp. 235–280.
    (Cơ sở lý thuyết về giao thức TCP, cơ chế hướng luồng byte stream, điều khiển luồng và tắc nghẽn).

[2] W. R. Stevens, B. Fenner, and A. M. Rudoff, UNIX Network Programming, Volume 1: 
    The Sockets Networking API, 3rd ed. Boston, MA, USA: Addison-Wesley Professional, 2004.
    (Nguyên lý lập trình Socket, phân đoạn TCP, cơ chế phân tách gói tin Length-Prefix Framing).

[3] J. Dean and L. A. Barroso, "The Tail at Scale," Communications of the ACM, 
    vol. 56, no. 2, pp. 74–80, Feb. 2013, doi: 10.1145/2408776.2408794.
    (Ý nghĩa học thuật của độ trễ đuôi p95/p99 Tail Latency và hiện tượng bão hòa tài nguyên hệ thống phân tán).

[4] Oracle Corporation, "Java Platform, Standard Edition Documentation - Networking and Sockets API (JDK 21 LTS)," 
    Oracle Technology Network, 2023. [Online]. Available: https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/net/Socket.html.
    (Tài liệu kỹ thuật chính thức về java.net.Socket, ServerSocket và ExecutorService trong Java 21).

[5] B. Goetz, T. Peierls, J. Bloch, J. Bowbeer, D. Holmes, and D. Lea, 
    Java Concurrency in Practice. Boston, MA, USA: Addison-Wesley Professional, 2006.
    (Mô hình Thread Pool, chi phí Context Switching và lập trình đa luồng an toàn).
```

### 8.2. Tuyên Bố Sử Dụng Công Cụ Trí Tuệ Nhân Tạo (AI Usage Declaration)

* **Công cụ AI sử dụng:** Trợ lý trí tuệ nhân tạo (AI Coding Assistant).
* **Mục đích và Phạm vi sử dụng:**
  * Hỗ trợ rà soát cú pháp và tối ưu hóa câu từ học thuật trong các đoạn văn bản báo cáo tiếng Việt.
  * Hỗ trợ tạo khung mẫu biểu đồ chuẩn quy chuẩn hiển thị (300 DPI) bằng thư viện `matplotlib`.
  * Hỗ trợ gợi ý các ca kiểm thử biên (edge cases) trong bài kiểm tra chịu lỗi phân mảnh byte.
* **Cam kết học thuật:** Toàn bộ ý tưởng thiết kế kiến trúc hệ thống, mã nguồn TCP Server và Load Generator, quy trình chạy thực nghiệm trên máy tính thực tế, cũng như các số liệu đo đạc và phân tích kết luận đều do 6 thành viên trong nhóm trực tiếp xây dựng, kiểm chứng và chịu trách nhiệm hoàn toàn về tính trung thực.
