
USE master;
GO
-- TỰ ĐỘNG XÓA DATABASE CŨ ĐỂ TRÁNH LỖI "ALREADY EXISTS"
IF EXISTS (SELECT * FROM sys.databases WHERE name = 'QuanLyCamDo')
BEGIN
    ALTER DATABASE QuanLyCamDo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE QuanLyCamDo;
END
GO

CREATE DATABASE QuanLyCamDo;
GO
USE QuanLyCamDo;
GO

-- =============================================
-- NHIỆM VỤ 1: THIẾT KẾ CSDL (Chuẩn 3NF)
-- =============================================

CREATE TABLE KhachHang (
    MaKH INT PRIMARY KEY IDENTITY(1,1),
    TenKH NVARCHAR(100) NOT NULL,
    SDT VARCHAR(15) NOT NULL UNIQUE,
    DiaChi NVARCHAR(255)
);

CREATE TABLE HopDong (
    MaHD INT PRIMARY KEY IDENTITY(1,1),
    MaKH INT FOREIGN KEY REFERENCES KhachHang(MaKH),
    TienGoc MONEY NOT NULL,
    NgayLap DATETIME DEFAULT GETDATE(),
    Deadline1 DATETIME NOT NULL, -- Mốc bắt đầu tính lãi kép
    Deadline2 DATETIME NOT NULL, -- Mốc bắt đầu thanh lý
    TrangThai NVARCHAR(50) DEFAULT N'Đang vay' 
);

CREATE TABLE TaiSan (
    MaTS INT PRIMARY KEY IDENTITY(1,1),
    MaHD INT FOREIGN KEY REFERENCES HopDong(MaHD),
    TenTS NVARCHAR(100),
    GiaTriDinhGia MONEY,
    TrangThaiTS NVARCHAR(50) DEFAULT N'Đang cầm cố', -- Đang cầm, Đã trả khách, Sẵn sàng thanh lý, Đã bán
    IsSold BIT DEFAULT 0
);

-- AUDIT LOG: Ghi lại lịch sử trả tiền (Sự kiện bổ sung)
CREATE TABLE LogGiaoDich (
    LogID INT PRIMARY KEY IDENTITY(1,1),
    MaHD INT FOREIGN KEY REFERENCES HopDong(MaHD),
    NgayGiaoDich DATETIME DEFAULT GETDATE(),
    SoTienTra MONEY,
    NoiDung NVARCHAR(255),
    NguoiThuTien NVARCHAR(50)
);
GO

-- =============================================
-- EVENT 2: HÀM TÍNH TOÁN CÔNG NỢ (LÃI ĐƠN & LÃI KÉP)
-- =============================================
CREATE FUNCTION fn_CalcMoneyContract (@MaHD INT, @TargetDate DATETIME)
RETURNS MONEY
AS
BEGIN
    DECLARE @TienGoc MONEY, @NgayLap DATETIME, @DL1 DATETIME;
    DECLARE @TongNo MONEY, @DaysDon INT, @DaysKep INT;
    DECLARE @LaiSuat FLOAT = 0.005; -- 5.000đ/1.000.000đ mỗi ngày

    SELECT @TienGoc = TienGoc, @NgayLap = NgayLap, @DL1 = Deadline1 
    FROM HopDong WHERE MaHD = @MaHD;

    -- 1. Nếu chưa tới Deadline 1: Tính lãi đơn
    IF @TargetDate <= @DL1
    BEGIN
        SET @DaysDon = DATEDIFF(DAY, @NgayLap, @TargetDate);
        IF @DaysDon < 0 SET @DaysDon = 0;
        SET @TongNo = @TienGoc * (1 + @DaysDon * @LaiSuat);
    END
    -- 2. Nếu đã qua Deadline 1: Tính lãi kép dựa trên nợ tích lũy tại DL1
    ELSE
    BEGIN
        SET @DaysDon = DATEDIFF(DAY, @NgayLap, @DL1);
        DECLARE @NoTaiDL1 MONEY = @TienGoc * (1 + @DaysDon * @LaiSuat);
        SET @DaysKep = DATEDIFF(DAY, @DL1, @TargetDate);
        -- Công thức lãi kép: A = P * (1 + r)^n
        SET @TongNo = @NoTaiDL1 * POWER(1 + @LaiSuat, @DaysKep);
    END

    -- Trừ đi số tiền khách đã thực trả trong bảng Log
    DECLARE @DaTra MONEY = (SELECT ISNULL(SUM(SoTienTra), 0) FROM LogGiaoDich WHERE MaHD = @MaHD);
    RETURN @TongNo - @DaTra;
END;
GO

-- =============================================
-- EVENT 1: TIẾP NHẬN HỢP ĐỒNG MỚI
-- =============================================
CREATE PROCEDURE sp_RegisterContract
    @TenKH NVARCHAR(100), @SDT VARCHAR(15), @TienGoc MONEY, 
    @DaysToDL1 INT, @DaysToDL2 INT, @TenTS NVARCHAR(100), @GiaTriTS MONEY
AS
BEGIN
    IF NOT EXISTS (SELECT 1 FROM KhachHang WHERE SDT = @SDT)
        INSERT INTO KhachHang(TenKH, SDT) VALUES (@TenKH, @SDT);
    
    DECLARE @MaKH INT = (SELECT MaKH FROM KhachHang WHERE SDT = @SDT);
    
    INSERT INTO HopDong(MaKH, TienGoc, Deadline1, Deadline2)
    VALUES (@MaKH, @TienGoc, DATEADD(DAY, @DaysToDL1, GETDATE()), DATEADD(DAY, @DaysToDL2, GETDATE()));
    
    DECLARE @MaHD INT = SCOPE_IDENTITY();
    INSERT INTO TaiSan(MaHD, TenTS, GiaTriDinhGia) VALUES (@MaHD, @TenTS, @GiaTriTS);
END;
GO

-- =============================================
-- EVENT 3: XỬ LÝ TRẢ NỢ & ĐIỀU KIỆN TRẢ ĐỒ
-- =============================================
CREATE PROCEDURE sp_ProcessPayment
    @MaHD INT, @SoTienTra MONEY, @NguoiThu NVARCHAR(50)
AS
BEGIN
    -- Kiểm tra nếu đã bị thanh lý thì không cho trả nợ nữa
    IF EXISTS (SELECT 1 FROM TaiSan WHERE MaHD = @MaHD AND IsSold = 1)
    BEGIN
        PRINT N'Tài sản đã bán thanh lý. Không thể thực hiện giao dịch.';
        RETURN;
    END

    -- Ghi Log giao dịch
    INSERT INTO LogGiaoDich(MaHD, SoTienTra, NoiDung, NguoiThuTien)
    VALUES (@MaHD, @SoTienTra, N'Khách trả nợ từng phần', @NguoiThu);

    -- Tính dư nợ sau khi trả
    DECLARE @DuNo MONEY = dbo.fn_CalcMoneyContract(@MaHD, GETDATE());

    IF @DuNo <= 0
        UPDATE HopDong SET TrangThai = N'Đã thanh toán đủ' WHERE MaHD = @MaHD;
    ELSE
        UPDATE HopDong SET TrangThai = N'Đang trả góp' WHERE MaHD = @MaHD;

    -- Logic Trả đồ: Chỉ gợi ý trả đồ nếu tổng giá trị các món còn lại >= dư nợ
    PRINT N'--- Gợi ý tài sản có thể hoàn trả cho khách ---';
    SELECT MaTS, TenTS, GiaTriDinhGia 
    FROM TaiSan 
    WHERE MaHD = @MaHD AND TrangThaiTS = N'Đang cầm cố'
    AND (SELECT ISNULL(SUM(GiaTriDinhGia),0) FROM TaiSan TS2 
         WHERE TS2.MaHD = @MaHD AND TS2.MaTS <> TaiSan.MaTS AND TS2.TrangThaiTS = N'Đang cầm cố') >= @DuNo;
END;
GO

-- =============================================
-- EVENT 4: TRUY VẤN DANH SÁCH NỢ XẤU (BÁO CÁO)
-- =============================================
CREATE PROCEDURE sp_ReportBadDebt
AS
BEGIN
    SELECT 
        k.TenKH AS [Tên Khách Hàng],
        k.SDT AS [Số Điện Thoại],
        h.TienGoc AS [Gốc Vay],
        DATEDIFF(DAY, h.Deadline1, GETDATE()) AS [Số Ngày Quá Hạn],
        dbo.fn_CalcMoneyContract(h.MaHD, GETDATE()) AS [Dư Nợ Hiện Tại],
        dbo.fn_CalcMoneyContract(h.MaHD, DATEADD(MONTH, 1, GETDATE())) AS [Dự Báo Nợ Sau 1 Tháng]
    FROM KhachHang k 
    JOIN HopDong h ON k.MaKH = h.MaKH
    WHERE GETDATE() > h.Deadline1 
      AND h.TrangThai NOT IN (N'Đã thanh toán đủ', N'Đã thanh lý');
END;
GO

-- =============================================
-- EVENT 5: QUẢN LÝ THANH LÝ (3 TRIGGER TỰ ĐỘNG)
-- =============================================
CREATE TRIGGER trg_AutoManagement ON HopDong AFTER UPDATE AS
BEGIN
    -- 1. Chuyển sang nợ xấu nếu quá Deadline 1
    UPDATE HopDong SET TrangThai = N'Quá hạn (nợ xấu)' 
    FROM HopDong h INNER JOIN inserted i ON h.MaHD = i.MaHD
    WHERE GETDATE() > h.Deadline1 AND h.TrangThai = N'Đang vay';

    -- 2. Chuyển tài sản sang "Sẵn sàng thanh lý" nếu quá Deadline 2
    UPDATE TaiSan SET TrangThaiTS = N'Sẵn sàng thanh lý'
    FROM TaiSan t INNER JOIN inserted i ON t.MaHD = i.MaHD
    WHERE GETDATE() > i.Deadline2 AND i.TrangThai = N'Quá hạn (nợ xấu)';

    -- 3. Cập nhật tài sản khi chuyển trạng thái "Đã thanh lý"
    UPDATE TaiSan SET TrangThaiTS = N'Đã bán thanh lý', IsSold = 1
    FROM TaiSan t INNER JOIN inserted i ON t.MaHD = i.MaHD
    WHERE i.TrangThai = N'Đã thanh lý';
END;
GO

-- =============================================
-- SỰ KIỆN BỔ SUNG: GIA HẠN HỢP ĐỒNG
-- =============================================
CREATE PROCEDURE sp_ExtendContract
    @MaHD INT, @DaysExtend INT, @NguoiThu NVARCHAR(50)
AS
BEGIN
    DECLARE @LaiHienTai MONEY = dbo.fn_CalcMoneyContract(@MaHD, GETDATE()) - (SELECT TienGoc FROM HopDong WHERE MaHD = @MaHD);
    
    -- Ghi Log thu tiền lãi để gia hạn
    INSERT INTO LogGiaoDich(MaHD, SoTienTra, NoiDung, NguoiThuTien)
    VALUES (@MaHD, @LaiHienTai, N'Trả lãi để gia hạn hợp đồng', @NguoiThu);

    -- Dời Deadline
    UPDATE HopDong 
    SET Deadline1 = DATEADD(DAY, @DaysExtend, GETDATE()),
        Deadline2 = DATEADD(DAY, @DaysExtend + 10, GETDATE()),
        TrangThai = N'Đang vay'
    WHERE MaHD = @MaHD;
END;
GO

-- =============================================
-- TEST DỮ LIỆU MẪU (SAMPLEDATA)
-- =============================================

-- 1. Đăng ký hợp đồng (Quá hạn 15 ngày để test lãi kép)
EXEC sp_RegisterContract N'Đoàn Quân', '0912345678', 10000000, -10, 5, N'iPhone 15 Pro', 25000000;

-- 2. Xem danh sách nợ xấu (Kết quả Event 4)
EXEC sp_ReportBadDebt;

-- 3. Khách trả bớt 2 triệu (Kết quả Event 3)
EXEC sp_ProcessPayment 1, 2000000, N'Admin';

-- 4. Xem lại log giao dịch (Audit Log)
SELECT * FROM LogGiaoDich;