package org.raku.nqp.runtime;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.nio.channels.FileChannel;
import java.nio.BufferUnderflowException;
import java.nio.BufferOverflowException;
import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.jar.JarInputStream;
import java.util.zip.ZipEntry;
import org.tukaani.xz.XZInputStream;

public class LibraryLoader {
    static Map<String,Class<?>> sharedClasses = new ConcurrentHashMap<String,Class<?>>();

    public static void load(ThreadContext tc, String origFilename) {
        // Don't load the same thing multiple times.
        if (!tc.gc.loaded.add(origFilename))
            return;

        try {
            // Read in class data.
            String filename = origFilename;
            File file = new File(filename);
            if (!file.exists() && filename.equals("ModuleLoader.class")) {
                /* We special case the initial ModuleLoader loading. */
                String[] cps = System.getProperty("java.class.path").split("[:;]");
                for (int i = 0; i < cps.length; i++) {
                    file = new File(cps[i] + "/" + filename);
                    if (file.exists()) {
                        filename = cps[i] + "/" + filename;
                        break;
                    }
                    file = new File(cps[i] + "/ModuleLoader.jar");
                    if (file.exists()) {
                        filename = cps[i] + "/ModuleLoader.jar";
                        break;
                    }
                }
            }

            loadClass(tc, loadFile(filename, tc.gc.sharingHint));
        }
        catch (IOException | IllegalArgumentException | ClassNotFoundException e) {
            throw ExceptionHandling.dieInternal(tc, e.toString());
        }
    }

    public static void load(ThreadContext tc, byte[] buffer) {
        ByteBuffer bb;
        try {
            bb = ByteBuffer.allocate(buffer.length);
            bb.put(buffer);
            bb.rewind();
        }
        catch (BufferOverflowException | IllegalArgumentException e) {
            throw ExceptionHandling.dieInternal(tc, e);
        }
        load(tc, bb);
    }

    public static void load(ThreadContext tc, ByteBuffer buffer) {
        try {
            loadClass(tc, loadJar(buffer));
        }
        catch (IOException | IllegalArgumentException | ClassNotFoundException e) {
            throw ExceptionHandling.dieInternal(tc, e);
        }
    }

    public static void loadClass(ThreadContext tc, Class<?> c) {
        try {
            CompilationUnit cu = (CompilationUnit)c.getDeclaredConstructor().newInstance();
            cu.shared = tc.gc.sharingHint;
            cu.initializeCompilationUnit(tc);
            cu.runLoadIfAvailable(tc);
        }
        catch (ReflectiveOperationException e) {
            throw ExceptionHandling.dieInternal(tc, e);
        }
    }

    public static Class<?> loadFile(String cn, boolean shared) throws IOException, IllegalArgumentException, ClassNotFoundException {
        if (shared)
            return sharedClasses.computeIfAbsent(cn, (k) -> {
                try {
                    return loadFile(k, false);
                }
                catch (IOException | IllegalArgumentException | ClassNotFoundException e) {
                    return null;
                }
            });

        RandomAccessFile ch = new RandomAccessFile(cn, "rw");
        byte[] ba = new byte[Math.min((int)ch.length(), 4)];
        ch.readFully(ba);

        int sig = (ba.length < 4)
            ? 0
            : ((ba[3] & 0xFF) | ((ba[2] & 0xFF) << 8) | ((ba[1] & 0xFF) << 16) | ((ba[0] & 0xFF) << 24));
        switch (sig) {
            case 0xCAFEBABE: // classfile
                return loadNew(cn, readToMmapBuffer(ch.getChannel()), null);
            case 0x504B0304: // jar
                return loadJar(readToMmapBuffer(ch.getChannel()));
            default:
                throw new IllegalArgumentException("Unrecognized bytecode format in " + cn);
        }
    }

    private static final int BUF_SIZE = 0x7FFF;

    public static ByteBuffer readToMmapBuffer(FileChannel bc) throws IOException {
        List<ByteBuffer> chunks = new ArrayList< >();
        int length = (int)bc.size();
        int offset = 0;
        int sizeof = Math.min(length, BUF_SIZE);
        do {
            chunks.add(bc.map(FileChannel.MapMode.READ_WRITE, offset, sizeof));
            length -= sizeof;
            offset += sizeof;
            sizeof  = Math.min(length, BUF_SIZE);
        } while (sizeof > 0);
        length = offset;

        ByteBuffer bb = ByteBuffer.allocate(offset);
        for (ByteBuffer chunk : chunks)
            bb.put(chunk);
        bb.rewind();
        return bb;
    }

    public static ByteBuffer readToHeapBuffer(InputStream is) throws IOException {
        return ByteBuffer.wrap(is.readAllBytes());
    }

    public static ByteBuffer readToHeapBufferXz(InputStream is) throws IOException {
        return readToHeapBuffer(new XZInputStream(is));
    }

    public static Class<?> loadJar(ByteBuffer bb) throws IOException, IllegalArgumentException, ClassNotFoundException {
        // This is a (non-empty, non-self-extracting) zip file
        // These are quite constrained for now
        ByteBuffer bytes = null;
        ByteBuffer serial = null;
        JarInputStream jis = new JarInputStream(new ByteBufferedInputStream(bb));
        ZipEntry je;
        String cn = null;
        while ((je = jis.getNextEntry()) != null) {
            String jf = je.getName();
            if (jf.endsWith(".class") && bytes == null)
                bytes = readToHeapBuffer(jis);
            else if (jf.endsWith(".serialized.xz")) {
                cn = je.getComment();
                serial = readToHeapBufferXz(jis);
            }
            else if (jf.endsWith(".serialized") && serial == null)
                serial = readToHeapBuffer(jis);
            else
                throw new IllegalArgumentException("Bytecode jar contains unexpected file " + jf);
        }
        if (bytes == null)
            throw new IllegalArgumentException("Bytecode jar lacks class file");
        if (serial == null)
            throw new IllegalArgumentException("Bytecode jar lacks serialization file");
        return loadNew(cn, bytes, serial);
    }

    private static class ByteBufferedInputStream extends InputStream {
        private final ByteBuffer bb;

        public ByteBufferedInputStream(ByteBuffer bb) {
            this.bb = bb;
        }

        public static ByteBufferedInputStream copy(ByteBuffer src) throws IllegalArgumentException {
            int offset = src.position();
            ByteBuffer bb = ByteBuffer.allocate(src.capacity() - offset);
            bb.put(src);
            bb.rewind();
            src.position(offset);
            return new ByteBufferedInputStream(bb);
        }

        public static InputStream nullInputStream() {
            return new ByteBufferedInputStream(null);
        }

        private int get() throws IOException {
            try {
                return bb.get();
            }
            catch (BufferUnderflowException e) {
                throw new IOException(e);
            }
        }

        private void get(byte[] dst) throws IOException {
            try {
                bb.get(dst);
            }
            catch (BufferUnderflowException e) {
                throw new IOException(e);
            }
        }

        @Override
        public int read() throws IOException {
            return bb != null && bb.hasRemaining() ? get() : -1;
        }

        @Override
        public int read(byte[] dst) throws IOException {
            if (bb == null)
                return -1;

            int length = Math.min(dst.length, available());
            if (length <= 0)
                return 0;

            byte[] src = new byte[length];
            get(src);
            System.arraycopy(src, 0, dst, 0, length);
            return length;
        }

        @Override
        public int read(byte[] dst, int offset, int length) throws IOException {
            if (bb == null)
                return -1;

            length = Math.min(length, available());
            if (length <= 0)
                return 0;

            byte[] src = new byte[length];
            get(src);
            System.arraycopy(src, 0, dst, offset, length);
            return length;
        }

        @Override
        public int readNBytes(byte[] dst, int offset, int length) throws IOException {
            if (bb == null)
                return -1;

            length = Math.min(length, available());
            if (length <= 0)
                return 0;

            byte[] src = new byte[length];
            get(src);
            System.arraycopy(src, 0, dst, offset, length);
            return length;
        }

        @Override
        public byte[] readAllBytes() throws IOException {
            byte[] dst = new byte[available()];
            if (dst.length > 0)
                read(dst);
            return dst;
        }

        @Override
        public long skip(long length) {
            if (bb == null)
                return 0;

            int offset = bb.position();
            length = Long.min(length, bb.capacity() - offset);
            bb.position(offset + (int)length);
            return length;
        }

        @Override
        public int available() {
            return bb == null ? 0 : (bb.capacity() - bb.position());
        }

        @Override
        public void reset() {
            if (bb != null)
                bb.rewind();
        }
    }

    public static Class<?> loadNew(String cn, ByteBuffer bytes, ByteBuffer serial) throws ClassNotFoundException {
        return new SerialClassLoader(bytes, serial).loadSerialClass(cn);
    }

    private static class SerialClassLoader extends ClassLoader {
        static { ClassLoader.registerAsParallelCapable(); }

        // XXX FIXME: The entire decompressed source of a class and its
        // serialization persist in memory as long as its classloader does,
        // which is as long as the class itself does. We depend on this being
        // true given our getResourceAsStream override even! Yikes!
        private ByteBuffer bytes;
        private ByteBuffer serial;

        public SerialClassLoader(ByteBuffer bytes, ByteBuffer serial) {
            super();
            this.bytes = bytes;
            this.serial = serial;
        }

        protected Class<?> findSerialClass(String name) throws ClassNotFoundException {
            try {
                return defineClass(name, this.bytes, null);
            }
            catch (NoClassDefFoundError e) {
                throw new ClassNotFoundException("serial class not named " + name, e);
            }
            catch (IndexOutOfBoundsException e) {
                throw new ClassNotFoundException("could not read serial class " + name, e);
            }
            catch (SecurityException e) {
                throw new ClassNotFoundException("serial class is insecurely named " + name, e);
            }
        }

        public Class<?> loadSerialClass(String name) throws ClassNotFoundException {
            synchronized (getClassLoadingLock(name)) {
                // Assuming we're only invoked once per instance:
                Class<?> klass = findSerialClass(name);
                // Should that not hold true:
                // Class<?> klass = findLoadedClass(name);
                // if (klass == null)
                //     klass = findSerialClass(name);
                resolveClass(klass);
                return klass;
            }
        }

        @Override
        protected Object getClassLoadingLock(String name) {
            return this;
        }

        @Override
        public InputStream getResourceAsStream(String name) {
            try {
                return ByteBufferedInputStream.copy(serial);
            }
            catch (IllegalArgumentException e) {
                return null;
            }
        }
    }
}
