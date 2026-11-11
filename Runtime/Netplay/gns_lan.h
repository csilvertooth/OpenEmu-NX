// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#pragma once
#include "wire.h"
#include <steam/steamnetworkingsockets.h>
#include <functional>
#include <string>
namespace emu {
class Lan {
public:
    Lan(bool host,const std::string &address,int lagMs,float loss);
    ~Lan();
    Lan(const Lan&)=delete; Lan& operator=(const Lan&)=delete;
    void poll(const std::function<void(const Bytes&)> &receive);
    void send(const Bytes &bytes);
    bool connected()const{return connected_;}
private:
    static Lan *owner_;
    static void callback(SteamNetConnectionStatusChangedCallback_t *event);
    ISteamNetworkingSockets *sockets_=nullptr;
    HSteamListenSocket listen_=k_HSteamListenSocket_Invalid;
    HSteamNetConnection connection_=k_HSteamNetConnection_Invalid;
    bool connected_=false;
    std::string failure_;
};
}
