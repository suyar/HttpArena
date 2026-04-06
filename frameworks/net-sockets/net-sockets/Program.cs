using System.Buffers;
using System.Buffers.Text;
using System.IO.Pipelines;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using Glyph11.Parser;
using Glyph11.Parser.FlexibleParser;
using Glyph11.Protocol;
using Glyph11.Validation;

// ReSharper disable StringLiteralTypo

namespace net_sockets;

internal class Program
{
    private static ReadOnlyMemory<byte> _data;

    private static ReadOnlySpan<byte> _dataSpan =>
        "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\nContent-Type: text/plain\r\n\r\nHello, World!"u8;

    private const int SOL_SOCKET = 1;
    private const int SO_REUSEPORT = 15; // Linux

    [DllImport("libc", SetLastError = true)]
    private static extern int setsockopt(
        int sockfd,
        int level,
        int optname,
        ref int optval,
        uint optlen);

    public static async Task Main(string[] args)
    {
        _data =
            "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\nContent-Type: text/plain\r\n\r\nHello, World!"u8
                .ToArray();

        if (!OperatingSystem.IsLinux())
            throw new PlatformNotSupportedException("This ReusePort example is Linux-only.");

        int listenerCount = Environment.ProcessorCount / 2;
        var listeners = new List<Socket>(listenerCount);

        for (int i = 0; i < listenerCount; i++)
        {
            var listener = CreateListener(8080);
            listeners.Add(listener);
        }

        var tasks = new Task[listeners.Count];
        for (int i = 0; i < listeners.Count; i++)
        {
            Socket localListener = listeners[i];
            tasks[i] = AcceptLoop(localListener);
        }

        await Task.WhenAll(tasks);
    }

    private static Socket CreateListener(int port)
    {
        var socket = new Socket(AddressFamily.InterNetworkV6, SocketType.Stream, ProtocolType.Tcp);

        socket.SetSocketOption(SocketOptionLevel.IPv6, SocketOptionName.IPv6Only, false);
        socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
        socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        socket.NoDelay = true;

        EnableReusePort(socket);

        socket.Bind(new IPEndPoint(IPAddress.IPv6Any, port));
        socket.Listen(1024 * 16);

        return socket;
    }

    private static void EnableReusePort(Socket socket)
    {
        int one = 1;

        int result = setsockopt(
            (int)socket.Handle,
            SOL_SOCKET,
            SO_REUSEPORT,
            ref one,
            sizeof(int));

        if (result == 0) 
            return;
        
        int errno = Marshal.GetLastWin32Error();
        throw new InvalidOperationException($"setsockopt(SO_REUSEPORT) failed. errno={errno}");
    }

    private static async Task AcceptLoop(Socket listener)
    {
        while (listener.Connected)
        {
            var client = await listener.AcceptAsync();
            client.NoDelay = true;

            //_ = HandleAsyncPipe(client);
            _ = HandleAsyncPipe(new NetworkStream(client, true));
        }
    }

    private static ReadOnlySpan<byte> CL => "Content Length"u8;
    private static ReadOnlySpan<byte> TE => "Transfer Encoding"u8;
    
    private static async ValueTask HandleAsyncPipe(Stream client)
    {
        PipeReader reader = PipeReader.Create(client);
        PipeWriter writer = PipeWriter.Create(client);
        
        BinaryRequest request = new BinaryRequest();
        ParserLimits limits = ParserLimits.Default;

        int advanced = 0;
        long bufferTotalSize = 0;
        
        try
        {
            while (true)
            {
                ReadResult result = await reader.ReadAsync();
                ReadOnlySequence<byte> buffer = result.Buffer;

                bufferTotalSize = buffer.Length;

                while (true)
                {
                    FlexibleParser.TryExtractFullHeader(ref buffer, request, out int bytesRead);

                    for (int i = 0; i < request.QueryParameters.Count; i++)
                    {
                        var paramKey = request.QueryParameters[i].Key;
                        var paramValue = request.QueryParameters[i].Value;

                        if (Utf8Parser.TryParse(paramValue.Span, out int value, out int consumed) &&
                            consumed == paramValue.Length)
                        {
                            Console.WriteLine(value);
                        }
                    }

                    var bodyFramingResult = BodyFramingDetector.DetectBodyFraming(request);

                    if (bodyFramingResult.Framing == BodyFraming.None)
                    {
                        reader.AdvanceTo(buffer.GetPosition(bytesRead));
                    }
                    else if (bodyFramingResult.Framing == BodyFraming.ContentLength)
                    {
                        long cl = bodyFramingResult.ContentLength;
                        long remaining = cl;

                        // Process body bytes already in the buffer after headers
                        long alreadyAvailable = buffer.Length - bytesRead;
                        if (alreadyAvailable > 0)
                        {
                            long take = Math.Min(alreadyAvailable, remaining);
                            var chunk = buffer.Slice(bytesRead, take);
                            // process chunk here
                            remaining -= take;
                            reader.AdvanceTo(buffer.GetPosition(bytesRead + take));
                        }
                        else
                        {
                            reader.AdvanceTo(buffer.GetPosition(bytesRead));
                        }

                        // Read remaining body from pipe
                        while (remaining > 0)
                        {
                            var bodyResult = await reader.ReadAsync();
                            var bodyBuffer = bodyResult.Buffer;
                            long take = Math.Min(bodyBuffer.Length, remaining);
                            var chunk = bodyBuffer.Slice(0, take);
                            // process chunk here
                            remaining -= take;
                            reader.AdvanceTo(bodyBuffer.GetPosition(take));
                        }
                    }
                    else if (bodyFramingResult.Framing == BodyFraming.Chunked)
                    {
                        var chunked = new ChunkedBodyStream();
                        var chunkBuffer = buffer.Slice(bytesRead);

                        while (true)
                        {
                            ReadOnlySpan<byte> span = chunkBuffer.IsSingleSegment
                                ? chunkBuffer.FirstSpan
                                : chunkBuffer.ToArray();

                            int totalConsumed = 0;
                            bool done = false;
                            while (true)
                            {
                                var cr = chunked.TryReadChunk(span[totalConsumed..], out int consumed, out int dataOffset, out int dataLength);
                                totalConsumed += consumed;

                                if (cr == ChunkResult.Completed) { done = true; break; }
                                if (cr == ChunkResult.NeedMoreData) break;
                                // process chunk payload: span[totalConsumed - consumed + dataOffset] for dataLength bytes
                            }

                            reader.AdvanceTo(chunkBuffer.GetPosition(totalConsumed));

                            if (done) break;

                            // Incomplete chunk — need more data from the pipe
                            var readResult = await reader.ReadAsync();
                            chunkBuffer = readResult.Buffer;
                        }
                    }

                    if (result.IsCanceled || result.IsCompleted || result.Buffer.IsEmpty)
                        break;

                    writer.Write(_dataSpan);

                    // Check if there is more data available on the buffer, if not - just move on to next await ReadAsync
                    if (advanced >= bufferTotalSize) break;
                }

                await writer.FlushAsync();
            }
        }
        finally
        {
            await reader.CompleteAsync();
            await writer.CompleteAsync();
            await client.DisposeAsync();
        }
    }
    
    private static bool ContentEquals(ReadOnlyMemory<byte> x, ReadOnlyMemory<byte> y)
    {
        if (x.Length != y.Length)
            return false;

        if (x.Equals(y))
            return true;

        return x.Span.SequenceEqual(y.Span);
    }
    
    private static bool ContentEquals(ReadOnlyMemory<byte> x, ReadOnlySpan<byte> y)
    {
        if (x.Length != y.Length)
            return false;

        return x.Span.SequenceEqual(y);
    }

    private static async ValueTask HandleAsync(Socket client)
    {
        byte[] buffer = new byte[32 * 1024];

        try
        {
            while (true)
            {
                int recv = await client.ReceiveAsync(buffer);

                if (recv <= 0)
                    break;

                await client.SendAsync(_data);
            }
        }
        catch
        {
            //
        }
        finally
        {
            client.Dispose();
        }
    }
}