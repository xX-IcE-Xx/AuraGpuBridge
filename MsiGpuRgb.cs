// MsiGpuRgb.cs — direct RGB control of MSI RTX 4090 Gaming X Trio (ITE9 controller)
// over the GPU's I2C bus via NVAPI. Protocol derived from OpenRGB's MSIGPUv2Controller
// (GPL-2.0) — register map: mode 0x22, R/G/B 0x30-0x32, brightness 0x36, speed 0x38,
// save 0x3F, controller at I2C address 0x68 on NVAPI port 1.
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace AuraGpuBridge
{
    public static class MsiGpu
    {
        // --- NVAPI interop -------------------------------------------------

        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr NvQueryInterface(uint id);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int InitDel();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int EnumGpusDel([In, Out] IntPtr[] handles, out int count);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int PciIdsDel(IntPtr h, out uint devId, out uint subSys, out uint rev, out uint extDev);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int I2cDel(IntPtr h, ref NvI2cInfoV3 info, ref uint unknown);

        [StructLayout(LayoutKind.Sequential)]
        private struct NvI2cInfoV3
        {
            public uint Version;
            public uint DisplayMask;
            public byte IsDdcPort;
            public byte DevAddress;      // 7-bit address << 1
            public IntPtr RegAddress;
            public uint RegAddrSize;
            public IntPtr Data;
            public uint Size;
            public uint Speed;           // deprecated field, must be 0xFFFF
            public uint SpeedKhz;        // 0 = default
            public byte PortId;
            public uint IsPortIdSet;
        }

        private static InitDel nvInit;
        private static EnumGpusDel nvEnum;
        private static PciIdsDel nvPciIds;
        private static I2cDel nvWrite;
        private static I2cDel nvRead;
        private static IntPtr gpuHandle = IntPtr.Zero;

        private static T GetFn<T>(uint id) where T : class
        {
            IntPtr p = NvQueryInterface(id);
            if (p == IntPtr.Zero)
                throw new InvalidOperationException("nvapi_QueryInterface returned null for 0x" + id.ToString("X8"));
            return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
        }

        // --- ITE9 register map (MSI GPU v2) --------------------------------

        private const byte I2C_ADDR        = 0x68;
        private const byte REG_MODE        = 0x22;
        private const byte REG_UNKNOWN     = 0x2E;
        private const byte REG_R1          = 0x30;
        private const byte REG_G1          = 0x31;
        private const byte REG_B1          = 0x32;
        private const byte REG_BRIGHTNESS  = 0x36;
        private const byte REG_SPEED       = 0x38;
        private const byte REG_SAVE        = 0x3F;
        private const byte REG_CONTROL     = 0x46;

        public const byte MODE_IDLE        = 0x1C;
        public const byte MODE_OFF         = 0x01;
        public const byte MODE_FLASHING    = 0x02;
        public const byte MODE_BREATHING   = 0x04;
        public const byte MODE_RAINBOW     = 0x08;
        public const byte MODE_STATIC      = 0x13;

        // --- public API ----------------------------------------------------

        public static string Status = "";

        public static void Connect()
        {
            if (gpuHandle != IntPtr.Zero) return;

            nvInit   = GetFn<InitDel>(0x0150E828);
            nvEnum   = GetFn<EnumGpusDel>(0xE5AC921F);
            nvPciIds = GetFn<PciIdsDel>(0x2DDFB66E);
            nvWrite  = GetFn<I2cDel>(0x283AC65A);
            nvRead   = GetFn<I2cDel>(0x4D7B0709);

            int rc = nvInit();
            if (rc != 0) throw new InvalidOperationException("NvAPI_Initialize failed: " + rc);

            IntPtr[] handles = new IntPtr[64];
            int count;
            rc = nvEnum(handles, out count);
            if (rc != 0) throw new InvalidOperationException("NvAPI_EnumPhysicalGPUs failed: " + rc);

            for (int i = 0; i < count; i++)
            {
                uint devId, subSys, rev, extDev;
                if (nvPciIds(handles[i], out devId, out subSys, out rev, out extDev) != 0) continue;
                // RTX 4090 (10DE:2684), MSI Gaming X Trio (1462:5103)
                if ((devId & 0xFFFF) == 0x10DE && (devId >> 16) == 0x2684 && subSys == 0x51031462)
                {
                    gpuHandle = handles[i];
                    Status = "Found MSI RTX 4090 Gaming X Trio (GPU " + i + " of " + count + ")";
                    return;
                }
            }
            throw new InvalidOperationException("MSI RTX 4090 Gaming X Trio (10DE:2684 / 1462:5103) not found among " + count + " GPU(s)");
        }

        private static int I2cTransfer(bool write, byte reg, byte[] buf)
        {
            IntPtr regPtr  = Marshal.AllocHGlobal(1);
            IntPtr dataPtr = Marshal.AllocHGlobal(Math.Max(buf.Length, 16));
            try
            {
                Marshal.WriteByte(regPtr, reg);
                if (write) Marshal.Copy(buf, 0, dataPtr, buf.Length);

                NvI2cInfoV3 info = new NvI2cInfoV3();
                info.Version     = (3u << 16) | (uint)Marshal.SizeOf(typeof(NvI2cInfoV3));
                info.DisplayMask = 0;
                info.IsDdcPort   = 0;
                info.DevAddress  = (byte)(I2C_ADDR << 1);
                info.RegAddress  = regPtr;
                info.RegAddrSize = 1;
                info.Data        = dataPtr;
                info.Size        = (uint)buf.Length;
                info.Speed       = 0xFFFF;
                info.SpeedKhz    = 0;    // NVAPI_I2C_SPEED_DEFAULT
                info.PortId      = 1;    // RGB controller lives on GPU I2C port 1
                info.IsPortIdSet = 1;

                uint unknown = 0;
                int rc = write ? nvWrite(gpuHandle, ref info, ref unknown)
                               : nvRead(gpuHandle, ref info, ref unknown);
                if (!write && rc == 0) Marshal.Copy(dataPtr, buf, 0, buf.Length);
                return rc;
            }
            finally
            {
                Marshal.FreeHGlobal(regPtr);
                Marshal.FreeHGlobal(dataPtr);
            }
        }

        /// Read-only probe of an arbitrary I2C address; returns raw NVAPI status (0 = ACK).
        public static int ProbeRead(byte addr, byte reg)
        {
            IntPtr regPtr  = Marshal.AllocHGlobal(1);
            IntPtr dataPtr = Marshal.AllocHGlobal(16);
            try
            {
                Marshal.WriteByte(regPtr, reg);
                NvI2cInfoV3 info = new NvI2cInfoV3();
                info.Version     = (3u << 16) | (uint)Marshal.SizeOf(typeof(NvI2cInfoV3));
                info.IsDdcPort   = 0;
                info.DevAddress  = (byte)(addr << 1);
                info.RegAddress  = regPtr;
                info.RegAddrSize = 1;
                info.Data        = dataPtr;
                info.Size        = 1;
                info.Speed       = 0xFFFF;
                info.SpeedKhz    = 0;
                info.PortId      = 1;
                info.IsPortIdSet = 1;
                uint unknown = 0;
                return nvRead(gpuHandle, ref info, ref unknown);
            }
            finally
            {
                Marshal.FreeHGlobal(regPtr);
                Marshal.FreeHGlobal(dataPtr);
            }
        }

        public static void WriteReg(byte reg, byte val)
        {
            int rc = I2cTransfer(true, reg, new byte[] { val });
            if (rc != 0) throw new InvalidOperationException("I2C write reg 0x" + reg.ToString("X2") + " failed: " + rc);
            Thread.Sleep(20);
        }

        public static int ReadReg(byte reg)
        {
            byte[] buf = new byte[1];
            int rc = I2cTransfer(false, reg, buf);
            if (rc != 0) return -rc - 1000;   // negative sentinel carrying NVAPI status
            return buf[0];
        }

        /// Static color; brightness 1..5 (hardware scale, x20 internally)
        public static void SetStatic(byte r, byte g, byte b, byte brightness)
        {
            WriteReg(REG_UNKNOWN, 0x00);
            WriteReg(REG_MODE, MODE_IDLE);
            WriteReg(REG_R1, r);
            WriteReg(REG_G1, g);
            WriteReg(REG_B1, b);
            WriteReg(REG_BRIGHTNESS, (byte)(20 * Math.Min(Math.Max((int)brightness, 1), 5)));
            WriteReg(REG_MODE, MODE_STATIC);
        }

        /// Hardware effect modes that take a color (breathing/flashing use color block writes)
        public static void SetEffect(byte mode, byte r, byte g, byte b, byte brightness, byte speed)
        {
            WriteReg(REG_UNKNOWN, 0x00);
            WriteReg(REG_MODE, MODE_IDLE);
            if (mode == MODE_BREATHING)
            {
                // color block 1: reg 0x27, 3 bytes B,G,R
                int rc = I2cTransfer(true, 0x27, new byte[] { b, g, r });
                if (rc != 0) throw new InvalidOperationException("I2C block write failed: " + rc);
                Thread.Sleep(20);
                rc = I2cTransfer(true, 0x28, new byte[] { b, g, r });
                if (rc != 0) throw new InvalidOperationException("I2C block write failed: " + rc);
                Thread.Sleep(20);
            }
            else
            {
                WriteReg(REG_R1, r);
                WriteReg(REG_G1, g);
                WriteReg(REG_B1, b);
            }
            WriteReg(REG_BRIGHTNESS, (byte)(20 * Math.Min(Math.Max((int)brightness, 1), 5)));
            WriteReg(REG_SPEED, (byte)Math.Min((int)speed, 2));
            WriteReg(REG_MODE, mode);
        }

        public static void SetOff()
        {
            WriteReg(REG_UNKNOWN, 0x00);
            WriteReg(REG_MODE, MODE_IDLE);
            WriteReg(REG_MODE, MODE_OFF);
        }

        /// Persist current state to controller flash (survives power cycle). Use sparingly.
        public static void Save()
        {
            WriteReg(REG_SAVE, 0x00);
        }
    }
}
