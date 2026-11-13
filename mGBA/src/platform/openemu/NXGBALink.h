/* Copyright (c) 2026 Chris Silvertooth.
 * SPDX-License-Identifier: MPL-2.0
 * Private, single-threaded two-handheld scheduler. No sockets or user saves.
 */
#ifndef NX_GBA_LINK_H
#define NX_GBA_LINK_H
#include <mgba/core/core.h>
#include <mgba/internal/arm/arm.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/sio/lockstep.h>

struct NXGBALink {
    struct GBASIOLockstep cable;
    struct GBASIOLockstepNode nodes[2];
    struct mCore *cores[2];
    int32_t credit[2];
    unsigned waiting;
    bool blocked[2];
};
static struct NXGBALink *NXLinkContext(struct mLockstep *l) { return l->context; }
static bool NXLinkSignal(struct mLockstep *l,unsigned mask) {
    struct NXGBALink *p=NXLinkContext(l);
    if(p->waiting) { p->waiting &= ~mask; if(!p->waiting)p->blocked[0]=false; }
    else if(mask&2)p->blocked[1]=false;
    return true;
}
static bool NXLinkWait(struct mLockstep *l,unsigned mask) {
    struct NXGBALink *p=NXLinkContext(l);p->waiting=mask;p->blocked[0]=mask!=0;p->blocked[1]=false;return true;
}
static void NXLinkAdd(struct mLockstep *l,int id,int32_t cycles) {
    struct NXGBALink *p=NXLinkContext(l);int target=id? id:1;
    p->credit[target]+=cycles;if(p->credit[target]>0)p->blocked[target]=false;
}
static int32_t NXLinkUse(struct mLockstep *l,int id,int32_t cycles) {
    struct NXGBALink *p=NXLinkContext(l);p->credit[id]-=cycles;
    if(p->credit[id]<=0)p->blocked[id]=true;
    return p->credit[id]>0?p->credit[id]:0;
}
static int32_t NXLinkUnused(struct mLockstep *l,int id) { return NXLinkContext(l)->credit[id]; }
static void NXLinkUnload(struct mLockstep *l,int id) {
    struct NXGBALink *p=NXLinkContext(l);p->waiting=0;p->blocked[0]=p->blocked[1]=false;p->credit[id]=0;
}
static struct NXGBALink *NXLinkCreate(struct mCore *a,struct mCore *b) {
    if(!a || !b || a==b)return NULL;
    struct NXGBALink *p=calloc(1,sizeof(*p));if(!p)return NULL;
    p->cores[0]=a;p->cores[1]=b;
    mLockstepInit(&p->cable.d);GBASIOLockstepInit(&p->cable);
    p->cable.d.context=p;p->cable.d.signal=NXLinkSignal;p->cable.d.wait=NXLinkWait;
    p->cable.d.addCycles=NXLinkAdd;p->cable.d.useCycles=NXLinkUse;
    p->cable.d.unusedCycles=NXLinkUnused;p->cable.d.unload=NXLinkUnload;
    for(int i=0;i<2;i++) { GBASIOLockstepNodeCreate(&p->nodes[i]);GBASIOLockstepAttachNode(&p->cable,&p->nodes[i]); }
    for(int i=0;i<2;i++) {
        struct GBASIO *s=&((struct GBA *)p->cores[i]->board)->sio;
        // The vendored SetDriver treats two NULL pointers as an active driver,
        // incorrectly loading a serial event while the machine is in GPIO mode.
        struct GBASIODriver *d=&p->nodes[i].d;d->p=s;d->init(d);
        s->drivers.normal=d;s->drivers.multiplayer=d;p->nodes[i].mode=s->mode;
        if(s->mode==SIO_NORMAL_8 || s->mode==SIO_NORMAL_32 || s->mode==SIO_MULTI){s->activeDriver=d;d->load(d);}
    }
    return p;
}
static void NXLinkDestroy(struct NXGBALink *p) {
    if(!p)return;
    for(int i=0;i<2;i++) {
        struct GBA *g=p->cores[i]->board;
        g->sio.activeDriver=NULL;g->sio.drivers.normal=NULL;g->sio.drivers.multiplayer=NULL;
        mTimingDeschedule(&g->timing,&p->nodes[i].event);
    }
    mLockstepDeinit(&p->cable.d);free(p);
}
static bool NXLinkFrame(struct NXGBALink *p) {
    uint32_t start[2]={p->cores[0]->frameCounter(p->cores[0]),p->cores[1]->frameCounter(p->cores[1])};
    // Every iteration yields to the other handheld. Never wait on wall-clock time.
    // A bounded failure is preferable to hanging the UI on unsupported cable use.
    for(unsigned budget=0;budget<200000;budget++) {
        bool done[2]={p->cores[0]->frameCounter(p->cores[0])!=start[0],p->cores[1]->frameCounter(p->cores[1])!=start[1]};
        if(done[0] && done[1])return true;
        bool ran=false;
        for(int i=0;i<2;i++)if((!done[i] || p->blocked[1-i]) && !p->blocked[i]) { p->cores[i]->runLoop(p->cores[i]);ran=true; }
        if(!ran){fprintf(stderr,"NX pair stalled done=%d,%d blocked=%d,%d credits=%d,%d waiting=%u phase=%d modes=%d,%d\n",done[0],done[1],p->blocked[0],p->blocked[1],p->credit[0],p->credit[1],p->waiting,p->cable.d.transferActive,p->nodes[0].mode,p->nodes[1].mode);return false;}
    }
    return false;
}
/* Local matched-build snapshot, explicitly zeroed and containing no pointers. */
struct NXGBALinkState {
    uint32_t version,waiting,blocked[2];int32_t credit[2];
    int32_t phase,cycles,multi,normal;uint16_t multiRecv[4];uint32_t normalRecv[4];
    struct { int32_t next,diff,mode,eventDelay;uint32_t so,finished,scheduled;uint16_t siocnt,rcnt;int32_t cpuNextEvent;uint32_t earlyExit,timingInterrupted;
        uint32_t keysActive;uint16_t serialData[6];
    } node[2];
};
static struct NXGBALinkState NXLinkSave(struct NXGBALink *p) {
    struct NXGBALinkState s;memset(&s,0,sizeof(s));s.version=2;s.waiting=p->waiting;
    s.phase=p->cable.d.transferActive;s.cycles=p->cable.d.transferCycles;s.multi=p->cable.attachedMulti;s.normal=p->cable.attachedNormal;
    memcpy(s.multiRecv,p->cable.multiRecv,sizeof(s.multiRecv));memcpy(s.normalRecv,p->cable.normalRecv,sizeof(s.normalRecv));
    for(int i=0;i<2;i++) { struct GBASIOLockstepNode *n=&p->nodes[i];struct mTiming *t=&((struct GBA *)p->cores[i]->board)->timing;
        struct GBA *g=n->d.p->p;
        s.node[i].timingInterrupted=g->timing.reroot!=NULL;
        s.node[i].keysActive=g->keysActive;
        // The disk-state register whitelist omits SIOMLT_SEND. Preserve the
        // actual serial data registers, including the outgoing cable word.
        memcpy(s.node[i].serialData,&g->memory.io[0x120/2],sizeof(s.node[i].serialData));
        s.node[i].cpuNextEvent=n->d.p->p->cpu->nextEvent;s.node[i].earlyExit=n->d.p->p->earlyExit;
        s.node[i].siocnt=n->d.p->siocnt;s.node[i].rcnt=n->d.p->rcnt;
        s.blocked[i]=p->blocked[i];s.credit[i]=p->credit[i];s.node[i].next=n->nextEvent;s.node[i].diff=n->eventDiff;
        s.node[i].mode=n->mode;s.node[i].so=n->normalSO;s.node[i].finished=n->transferFinished;
        s.node[i].scheduled=mTimingIsScheduled(t,&n->event);s.node[i].eventDelay=s.node[i].scheduled?mTimingUntil(t,&n->event):0;
    }return s;
}
// Loading one machine must not signal, interrupt, or unload the other machine.
// Core disk-state loading changes SIO mode and normally calls the cable driver.
static void NXLinkPrepareLoad(struct NXGBALink *p) {
    for(int i=0;i<2;i++) {
        struct GBA *g=p->cores[i]->board;
        mTimingDeschedule(&g->timing,&p->nodes[i].event);
        g->sio.activeDriver=NULL;g->sio.drivers.normal=NULL;g->sio.drivers.multiplayer=NULL;
    }
}
static bool NXLinkLoad(struct NXGBALink *p,const struct NXGBALinkState *s) {
    if(s->version!=2 || s->phase<TRANSFER_IDLE || s->phase>TRANSFER_FINISHED || s->multi<0 || s->multi>2 || s->normal<0 || s->normal>2)return false;
    // Rebind local function pointers via the driver's normal mode setup, then
    // restore both registers and cable timing after all setup side effects.
    for(int i=0;i<2;i++) {
        struct GBASIO *sio=&((struct GBA *)p->cores[i]->board)->sio;
        sio->drivers.normal=&p->nodes[i].d;sio->drivers.multiplayer=&p->nodes[i].d;
        sio->activeDriver=NULL;sio->mode=(enum GBASIOMode)-1;sio->siocnt=s->node[i].siocnt;
        GBASIOWriteRCNT(sio,s->node[i].rcnt);
    }
    p->waiting=s->waiting;p->cable.d.transferActive=s->phase;p->cable.d.transferCycles=s->cycles;
    p->cable.attachedMulti=s->multi;p->cable.attachedNormal=s->normal;
    memcpy(p->cable.multiRecv,s->multiRecv,sizeof(s->multiRecv));memcpy(p->cable.normalRecv,s->normalRecv,sizeof(s->normalRecv));
    for(int i=0;i<2;i++) { struct GBASIOLockstepNode *n=&p->nodes[i];struct mTiming *t=&((struct GBA *)p->cores[i]->board)->timing;
        n->d.p->siocnt=s->node[i].siocnt;n->d.p->rcnt=s->node[i].rcnt;
        p->blocked[i]=s->blocked[i];p->credit[i]=s->credit[i];n->nextEvent=s->node[i].next;n->eventDiff=s->node[i].diff;
        n->mode=s->node[i].mode;n->normalSO=s->node[i].so;n->transferFinished=s->node[i].finished;
        mTimingDeschedule(t,&n->event);if(s->node[i].scheduled)mTimingSchedule(t,&n->event,s->node[i].eventDelay);
        struct GBA *g=n->d.p->p;
        g->keysActive=s->node[i].keysActive;
        memcpy(&g->memory.io[0x120/2],s->node[i].serialData,sizeof(s->node[i].serialData));
        if(s->node[i].timingInterrupted)mTimingInterrupt(t);
        n->d.p->p->cpu->nextEvent=s->node[i].cpuNextEvent;n->d.p->p->earlyExit=s->node[i].earlyExit;
    }return true;
}
#endif
