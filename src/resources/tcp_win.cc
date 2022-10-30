// Copyright (C) 2022 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include "../top.h"

#ifdef TOIT_WINDOWS

#include <winsock2.h>
#include <windows.h>

#include "posix_socket_address.h"


#include <sys/time.h>

#include "../objects_inline.h"
#include "../process_group.h"

#include "../event_sources/event_win.h"

#include "tcp.h"
#include "error_win.h"

namespace toit {

class TCPResourceGroup : public ResourceGroup {
 public:
  TAG(TCPResourceGroup);
  TCPResourceGroup(Process* process, EventSource* event_source) : ResourceGroup(process, event_source) {}

  static SOCKET create_socket() {
    SOCKET socket = WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED);
    if (socket == INVALID_SOCKET) return socket;

    int yes = 1;
    if (setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char *>(&yes), sizeof(yes)) == SOCKET_ERROR) {
      close_keep_errno(socket);
      return INVALID_SOCKET;
    }

    return socket;
  }
 private:
  uint32_t on_event(Resource* resource, word data, uint32_t state) override {
    return reinterpret_cast<WindowsResource*>(resource)->on_event(
        reinterpret_cast<HANDLE>(data),
        state);
  }
};

const int READ_BUFFER_SIZE = 1 << 16;

class TCPSocketResource : public WindowsResource {
 public:
  TAG(TCPSocketResource);
  TCPSocketResource(TCPResourceGroup* resource_group, SOCKET socket, HANDLE read_event, HANDLE write_event)
      : WindowsResource(resource_group)
      , _socket(socket) {
    _read_buffer.buf = _read_data;
    _read_buffer.len = READ_BUFFER_SIZE;
    _read_overlapped.hEvent = read_event;
    _write_overlapped.hEvent = write_event;
    if (!issue_read_request()) {
      _error = WSAGetLastError();
      set_state(TCP_ERROR);
    } else {
      set_state(TCP_WRITE);
    }
  }

  SOCKET socket() const { return _socket; }
  DWORD read_count() const { return _read_count; }
  char* read_buffer() const { return _read_buffer.buf; }
  bool ready_for_write() const { return _write_buffer.buf == null; }
  bool ready_for_read() const { return _read_count != 0; }
  bool closed() const { return _closed; }
  int error() const { return _error; }

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>({ _read_overlapped.hEvent, _write_overlapped.hEvent });
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    if (event == _read_overlapped.hEvent) {
      //printf("read event: %llx\n", (word)this);
      if (receive_read_response())
        state |= TCP_READ;
      else {
        _error = WSAGetLastError();
        if (WSAGetLastError() == WSAECONNRESET) {
          state |= TCP_CLOSE | TCP_READ;
          _closed = true;
        } else
          state |= TCP_ERROR;
      }
    } else if (event == _write_overlapped.hEvent) {
      //printf("write event: %llx\n", (word)this);
      if (_write_buffer.buf != null) {
        free(_write_buffer.buf);
        _write_buffer.buf = null;
      }
      state |= TCP_WRITE;
    } else if (event == INVALID_HANDLE_VALUE) {
      // The event source sends INVALID_HANDLE_VALUE when the socket is closed.
      _error = WSAECONNRESET;
      _closed = true;
      state |= TCP_CLOSE | TCP_READ;
    }
    return state;
  }

  void do_close() override {
    closesocket(_socket);
    CloseHandle(_read_overlapped.hEvent);
    CloseHandle(_write_overlapped.hEvent);
  }

  bool issue_read_request() {
    _read_count = 0;
    DWORD flags = 0;
    int receive_result = WSARecv(_socket, &_read_buffer, 1, NULL, &flags, &_read_overlapped, NULL);
    if (receive_result == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
      return false;
    }
    return true;
  }

  bool receive_read_response() {
    DWORD flags;
    bool overlapped_result = WSAGetOverlappedResult(_socket, &_read_overlapped, &_read_count, false, &flags);
    //printf("overlapped_result=%d, _read_count=%lu, last_error=%d\n", overlapped_result, _read_count, WSAGetLastError());
    return overlapped_result;
  }

  bool send(const uint8* buffer, int length) {
    ASSERT(_write_buffer.buf == null);
    // We need to copy the buffer out to a long-lived heap object
    _write_buffer.buf = static_cast<char*>(malloc(length));
    memcpy(_write_buffer.buf, buffer, length);
    _write_buffer.len = length;

    DWORD tmp;
    int send_result = WSASend(_socket, &_write_buffer, 1, &tmp, 0, &_write_overlapped, NULL);

    if (send_result == 0) {
      //printf("Immediate write: data length = %d, actual transmitted = %lu\n", length, tmp);
      //WindowsEventSource::instance()->on_event(this, _write_event);
    } else if (WSAGetLastError() != WSA_IO_PENDING) {
      return false;
    }

    return true;
  }

 private:
  SOCKET _socket;

  WSABUF _read_buffer{};
  char _read_data[READ_BUFFER_SIZE]{};
  OVERLAPPED _read_overlapped{};
  DWORD _read_count = 0;

  WSABUF _write_buffer{};
  OVERLAPPED _write_overlapped{};

  bool _closed = false;
  int _error = 0;
};

class TCPServerSocketResource : public WindowsResource {
 public:
  TAG(TCPServerSocketResource);
  TCPServerSocketResource(TCPResourceGroup* resource_group, SOCKET socket, HANDLE event)
    : WindowsResource(resource_group)
    , _socket(socket)
    , _event(event) {}

  SOCKET socket() const { return _socket; }

  std::vector<HANDLE> events() override {
    return std::vector<HANDLE>({ _event });
  }

  uint32_t on_event(HANDLE event, uint32_t state) override {
    return state | TCP_READ;
  }

  void do_close() override {
    closesocket(_socket);
    CloseHandle(_event);
  }

 private:
  SOCKET _socket;
  HANDLE _event;
};

MODULE_IMPLEMENTATION(tcp, MODULE_TCP)

PRIMITIVE(init) {
  ByteArray* proxy = process->object_heap()->allocate_proxy();
  if (proxy == null) ALLOCATION_FAILED;

  auto resource_group = _new TCPResourceGroup(process, WindowsEventSource::instance());
  if (!resource_group) MALLOC_FAILED;

  if (!WindowsEventSource::instance()->use()) {
    resource_group->tear_down();
    WINDOWS_ERROR;
  }

  proxy->set_external_address(resource_group);
  return proxy;
}

PRIMITIVE(connect) {
  ARGS(TCPResourceGroup, resource_group, Blob, address, int, port, int, window_size);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  SOCKET socket = TCPResourceGroup::create_socket();
  if (socket == INVALID_SOCKET) WINDOWS_ERROR;

  if (window_size != 0 && setsockopt(socket, SOL_SOCKET, SO_RCVBUF,
                                     reinterpret_cast<char*>(&window_size), sizeof(window_size)) == -1) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  ToitSocketAddress socket_address(address.address(), address.length(), port);
  int result = connect(socket, socket_address.as_socket_address(), socket_address.port());
  if (result == SOCKET_ERROR && WSAGetLastError() != WSAEINPROGRESS) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  WSAEVENT read_event = WSACreateEvent();
  if (read_event == WSA_INVALID_EVENT) {
    close_keep_errno(socket);
    if (WSAGetLastError() == WSA_NOT_ENOUGH_MEMORY) MALLOC_FAILED;
    WINDOWS_ERROR;
  }

  WSAEVENT write_event = WSACreateEvent();
  if (write_event == WSA_INVALID_EVENT) {
    close_handle_keep_errno(read_event);
    if (WSAGetLastError() == WSA_NOT_ENOUGH_MEMORY) MALLOC_FAILED;
    WINDOWS_ERROR;
  }

  auto tcp_resource = _new TCPSocketResource(resource_group, socket, read_event, write_event);
  //printf("outgoing created: %llx\n", (word)tcp_resource);
  if (!tcp_resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(tcp_resource);

  resource_proxy->set_external_address(tcp_resource);

  return resource_proxy;
}

PRIMITIVE(accept) {
  ARGS(TCPResourceGroup, resource_group, TCPServerSocketResource, server_socket_resource);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  WSAEVENT read_event = WSACreateEvent();
  if (read_event == WSA_INVALID_EVENT) {
    if (WSAGetLastError() == WSA_NOT_ENOUGH_MEMORY) MALLOC_FAILED;
    WINDOWS_ERROR;
  }

  WSAEVENT write_event = WSACreateEvent();
  if (write_event == WSA_INVALID_EVENT) {
    close_handle_keep_errno(read_event);
    if (WSAGetLastError() == WSA_NOT_ENOUGH_MEMORY) MALLOC_FAILED;
    WINDOWS_ERROR;
  }

  //printf("primitive.accept\n");
  SOCKET socket = accept(server_socket_resource->socket(), NULL, NULL);
  if (socket == INVALID_SOCKET) {
    //printf("primitive.accept INVALID_SOCKET\n");
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    if (WSAGetLastError() == WSAEWOULDBLOCK)
      return process->program()->null_object();
    WINDOWS_ERROR;
  }

  auto tcp_resource = _new TCPSocketResource(resource_group, socket, read_event, write_event);
  //printf("incoming created: %llx\n", (word)tcp_resource);

  if (!tcp_resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(read_event);
    close_handle_keep_errno(write_event);
    MALLOC_FAILED;
  }

  resource_group->register_resource(tcp_resource);

  resource_proxy->set_external_address(tcp_resource);

  return resource_proxy;
}

PRIMITIVE(listen) {
  ARGS(TCPResourceGroup, resource_group, cstring, hostname, int, port, int, backlog);

  ByteArray* resource_proxy = process->object_heap()->allocate_proxy();
  if (resource_proxy == null) ALLOCATION_FAILED;

  ToitSocketAddress socket_address;
  if (!socket_address.lookup_address(hostname, port)) {
    WINDOWS_ERROR;
  };

  SOCKET socket = TCPResourceGroup::create_socket();
  if (socket == INVALID_SOCKET) WINDOWS_ERROR;
  //socket_address.dump();
  if (bind(socket, socket_address.as_socket_address(), socket_address.size()) == SOCKET_ERROR) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  if (listen(socket, backlog) == SOCKET_ERROR) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  WSAEVENT event = WSACreateEvent();
  if (event == WSA_INVALID_EVENT) {
    close_keep_errno(socket);
    WINDOWS_ERROR;
  }

  if (WSAEventSelect(socket, event, FD_ACCEPT) == SOCKET_ERROR) {
    close_keep_errno(socket);
    close_handle_keep_errno(event);
    WINDOWS_ERROR;
  }

  auto resource = _new TCPServerSocketResource(resource_group, socket, event);
  if (!resource) {
    close_keep_errno(socket);
    close_handle_keep_errno(event);
    MALLOC_FAILED;
  }

  //printf("registering server socket: r=%llx, event=%llx\n",(word)resource, (word)event);
  resource_group->register_resource(resource);

  resource_proxy->set_external_address(resource);
  return resource_proxy;
}

PRIMITIVE(write) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource, Blob, data, int, from, int, to);
  USE(proxy);

  //printf("primitive.write: %llx\n",(word)tcp_resource);
  if (!tcp_resource->ready_for_write()) return Smi::from(-1);

  if (from < 0 || from > to || to > data.length()) OUT_OF_BOUNDS;

  bool send_result = tcp_resource->send(data.address() + from, to - from);
  if (!send_result) WINDOWS_ERROR;

  return Smi::from(to-from);
}

PRIMITIVE(read)  {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource);
  USE(proxy);

  if (tcp_resource->closed()) return process->program()->null_object();

  if (!tcp_resource->ready_for_read()) return Smi::from(-1);

  //printf("primitive.read: %llx\n",(word)tcp_resource);
  ByteArray* array = process->allocate_byte_array(static_cast<int>(tcp_resource->read_count()));
  if (array == null) ALLOCATION_FAILED;

  memcpy(ByteArray::Bytes(array).address(), tcp_resource->read_buffer(), tcp_resource->read_count());

  if (!tcp_resource->issue_read_request()) WINDOWS_ERROR;

  return array;
}

static Object* get_address(SOCKET socket, Process* process, bool peer) {
  ToitSocketAddress socket_address;

  int result = socket_address.retrieve_address(socket, peer);
  if (result == SOCKET_ERROR) WINDOWS_ERROR;

  return socket_address.as_toit_string(process);
}

static Object* get_port(SOCKET socket, Process* process, bool peer) {
  ToitSocketAddress socket_address;

  int result = socket_address.retrieve_address(socket, peer);
  if (result == SOCKET_ERROR) WINDOWS_ERROR;

  return Smi::from(socket_address.port());
}

PRIMITIVE(get_option) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource, int, option);
  USE(proxy);
  SOCKET socket = tcp_resource->socket();

  switch (option) {
    case TCP_ADDRESS:
      return get_address(socket, process, false);

    case TCP_PEER_ADDRESS:
      return get_address(socket, process, true);

    case TCP_PORT:
      return get_port(socket, process, false);

    case TCP_PEER_PORT:
      return get_port(socket, process, true);

    case TCP_KEEP_ALIVE: {
      int value = 0;
      int size = sizeof(value);
      if (getsockopt(socket, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<char *>(&value), &size) == -1)
        WINDOWS_ERROR;

      return BOOL(value != 0);
    }

    case TCP_WINDOW_SIZE: {
      int value = 0;
      int size = sizeof(value);
      if (getsockopt(socket, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<char *>(&value), &size) == -1)
        WINDOWS_ERROR;

      return Smi::from(value);
    }

    default:
      return process->program()->unimplemented();
  }
}

PRIMITIVE(set_option) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource, int, option, Object, raw);
  USE(proxy);

  if (option == TCP_KEEP_ALIVE) {
    int value = 0;
    if (raw == process->program()->true_object()) {
      value = 1;
    } else if (raw != process->program()->false_object()) {
      WRONG_TYPE;
    }
    if (setsockopt(tcp_resource->socket(), SOL_SOCKET, SO_KEEPALIVE,
                   reinterpret_cast<char*>(&value), sizeof(value)) == SOCKET_ERROR) {
      WINDOWS_ERROR;
    }
  } else {
    return process->program()->unimplemented();
  }

  return process->program()->null_object();
}

PRIMITIVE(close_write) {
  ARGS(ByteArray, proxy, TCPSocketResource, tcp_resource);
  USE(proxy);

  int result = shutdown(tcp_resource->socket(), SD_SEND);
  if (result != 0) WINDOWS_ERROR;

  return process->program()->null_object();
}

PRIMITIVE(close) {
  ARGS(TCPResourceGroup, resource_group, Resource, resource);
  // The event source will call do_close on the resource when it is safe to close the socket
  resource_group->unregister_resource(resource);

  resource_proxy->clear_external_address();

  return process->program()->null_object();
}

PRIMITIVE(error) {
  ARGS(TCPSocketResource, tcp_resource);
  return Primitive::unmark_from_error(windows_error(process, tcp_resource->error()));
}

PRIMITIVE(gc) {
  // Malloc never fails on Mac, so we should never try to trigger a GC.
  UNREACHABLE();
}

} // namespace toit

#endif // TOIT_BSD
