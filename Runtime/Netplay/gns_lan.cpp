// Copyright (c) 2026 Chris Silvertooth. SPDX-License-Identifier: BSD-3-Clause
#include "gns_lan.h"
#include <steam/isteamnetworkingutils.h>
#include <memory>
namespace emu {
Lan *Lan::owner_=nullptr;
Lan::Lan(bool host,const std::string &address,int lagMs,float loss) {
    if(owner_)throw std::runtime_error("one GNS owner per process");
    SteamNetworkingIPAddr endpoint;endpoint.Clear();
    if(!endpoint.ParseString(address.c_str()) || !endpoint.m_port)
        throw std::runtime_error("expected numeric IP:port");
    SteamDatagramErrMsg error;
    if(!GameNetworkingSockets_Init(nullptr,error))throw std::runtime_error(error);
    owner_=this;sockets_=SteamNetworkingSockets();
    try {
        SteamNetworkingUtils()->SetGlobalConfigValueInt32(k_ESteamNetworkingConfig_FakePacketLag_Send,lagMs);
        SteamNetworkingUtils()->SetGlobalConfigValueFloat(k_ESteamNetworkingConfig_FakePacketLoss_Send,loss);
        SteamNetworkingConfigValue_t options[7];
        options[0].SetPtr(k_ESteamNetworkingConfig_Callback_ConnectionStatusChanged,reinterpret_cast<void*>(&callback));
        options[1].SetInt32(k_ESteamNetworkingConfig_IP_AllowWithoutAuth,2);
        options[2].SetInt32(k_ESteamNetworkingConfig_SendBufferSize,64*1024);
        options[3].SetInt32(k_ESteamNetworkingConfig_RecvBufferSize,64*1024);
        options[4].SetInt32(k_ESteamNetworkingConfig_RecvBufferMessages,256);
        options[5].SetInt32(k_ESteamNetworkingConfig_RecvMaxMessageSize,512);
        options[6].SetInt32(k_ESteamNetworkingConfig_TimeoutConnected,5000);
        if(host) {
            listen_=sockets_->CreateListenSocketIP(endpoint,7,options);
            if(listen_==k_HSteamListenSocket_Invalid)throw std::runtime_error("GNS listen failed");
        } else {
            connection_=sockets_->ConnectByIPAddress(endpoint,7,options);
            if(connection_==k_HSteamNetConnection_Invalid)throw std::runtime_error("GNS connect failed");
        }
    } catch (...) { owner_=nullptr;GameNetworkingSockets_Kill();throw; }
}
Lan::~Lan() {
    if(connection_!=k_HSteamNetConnection_Invalid)sockets_->CloseConnection(connection_,0,"session ended",true);
    if(listen_!=k_HSteamListenSocket_Invalid)sockets_->CloseListenSocket(listen_);
    owner_=nullptr;GameNetworkingSockets_Kill();
}
void Lan::callback(SteamNetConnectionStatusChangedCallback_t *e) {
    auto *p=owner_;if(!p)return;
    if(e->m_info.m_eState==k_ESteamNetworkingConnectionState_Connecting && e->m_info.m_hListenSocket==p->listen_ && p->listen_!=k_HSteamListenSocket_Invalid) {
        if(p->connection_!=k_HSteamNetConnection_Invalid) {p->sockets_->CloseConnection(e->m_hConn,0,"session full",false);return;}
        p->connection_=e->m_hConn;
        if(p->sockets_->AcceptConnection(e->m_hConn)!=k_EResultOK)p->failure_="GNS accept failed";
    }
    if(e->m_hConn!=p->connection_)return;
    if(e->m_info.m_eState==k_ESteamNetworkingConnectionState_Connected)p->connected_=true;
    if(e->m_info.m_eState==k_ESteamNetworkingConnectionState_ClosedByPeer || e->m_info.m_eState==k_ESteamNetworkingConnectionState_ProblemDetectedLocally)
        p->failure_="connection ended: "+std::to_string(e->m_info.m_eEndReason);
}
void Lan::poll(const std::function<void(const Bytes&)> &receive) {
    sockets_->RunCallbacks();
    if(!failure_.empty())throw std::runtime_error(failure_);
    if(!connected_)return;
    for(int i=0;i<64;++i) {
        SteamNetworkingMessage_t *message=nullptr;
        int count=sockets_->ReceiveMessagesOnConnection(connection_,&message,1);
        if(count<0)throw std::runtime_error("GNS receive failed");
        if(!count)break;
        auto release=[](SteamNetworkingMessage_t *m){m->Release();};
        std::unique_ptr<SteamNetworkingMessage_t,decltype(release)> owned(message,release);
        if(message->m_cbSize<16 || message->m_cbSize>512)throw std::runtime_error("invalid message size");
        auto *p=static_cast<const uint8_t*>(message->m_pData);
        receive(Bytes(p,p+message->m_cbSize));
    }
}
void Lan::send(const Bytes &bytes) {
    if(!connected_ || bytes.size()<16 || bytes.size()>512)throw std::runtime_error("invalid send");
    if(sockets_->SendMessageToConnection(connection_,bytes.data(),uint32_t(bytes.size()),k_nSteamNetworkingSend_ReliableNoNagle,nullptr)!=k_EResultOK)
        throw std::runtime_error("GNS reliable send failed or queue full");
}
}
