/*
 * Copyright (c) 2012, Mid Sweden University
 * All rights reserved.
 *
 * Permission to use, copy, modify, and distribute this software and its
 * documentation for any purpose, without fee, and without written agreement is
 * hereby granted, provided that the above copyright notice, the following
 * two paragraphs and the author appear in all copies of this software.
 *
 * IN NO EVENT SHALL THE VANDERBILT UNIVERSITY BE LIABLE TO ANY PARTY FOR
 * DIRECT, INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING OUT
 * OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF THE VANDERBILT
 * UNIVERSITY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * THE VANDERBILT UNIVERSITY SPECIFICALLY DISCLAIMS ANY WARRANTIES,
 * INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS FOR A PARTICULAR PURPOSE.  THE SOFTWARE PROVIDED HEREUNDER IS
 * ON AN "AS IS" BASIS, AND THE VANDERBILT UNIVERSITY HAS NO OBLIGATION TO
 * PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS, OR MODIFICATIONS.
 *
 * @author:Wei Shen (wei.shen@miun.se)
 * Modify CC2420CsmaP.nc. The author are ...
 */

#include <stdio.h>
#include <stdint.h>

module PriorityMACP @safe() {

  provides interface SplitControl;
  provides interface Receive;
  provides interface Init;
  provides interface Send as SendCSMA; //2012-05-31
  //provides interface PMACSlotTime;
  provides interface PMACSlot;
  //provides interface RadioBackoff;

  uses interface Resource;
  uses interface CC2420Power;
  uses interface StdControl as SubControl;
  uses interface CC2420Transmit;
  //uses interface RadioBackoff as SubBackoff;
  uses interface Random;
  uses interface Leds;
  uses interface CC2420Packet;
  uses interface CC2420PacketBody;
  uses interface State as SplitControlState;
  //uses interface Boot;
  //uses interface Timer<TMilli>;
  uses interface Alarm<TMicro,uint16_t> as SlotAlarm;
  //uses interface Alarm<TMicro,uint16_t> as CCAAlarm;
  //uses interface LocalTime<TMicro> as MicroTimer;
  uses interface Receive as SubReceive;
  
  uses interface PacketTimeSyncOffset;
  uses interface PacketTimeStamp<T32khz,uint32_t> as PacketTimeStamp32khz;
  uses interface PMACQueue;
  
  uses interface GeneralIO as CCA; //weishen
  uses interface Alarm<T32khz,uint16_t> as Alarm32k;

}

implementation {

  enum {
    S_STOPPED,
    S_STARTING,
    S_STARTED,
    S_STOPPING,
    S_TRANSMITTING,
  };

 enum{
    ST_SLOT,
    ST_HPIS_END,
    ST_HPIS_CCA,
    //ST_HPIS_ONE,
    //ST_HPIS_TWO,
 };    
 
 /*enum{
     SLOT_TIME = 328,//in 2"15, 10.009, 11600, //ticks in TMicro. 1.106262188×10⁴ us
     HPIS_TIME = 660,//in 2¨20
 };

 enum{
     CCA_SAMPLE_TIME = 135, //8 symbol periods = 128 us.= 135 microticks. 1.048576 * 128
 };*/

 uint8_t slotState;

 RecordPacket tc1Packet, tc2Packet, tc3Packet;
 //-----------------------------------------------------------------

 // bool sendBusy = FALSE;
  uint16_t seqno;
  uint32_t abSltNum; //reSltNum
  
  message_t sendTimeSyncMsg; 

  void sendSyncPacket();

  message_t* ONE_NOK m_msg;
  
  error_t sendErr = SUCCESS;
  
  /** TRUE if we are to use CCA when sending the current packet */
  norace bool ccaOn;
  norace bool isTimeSyncROOT;
  bool sndMsgBusy;
  //uint8_t tc4ReadyReport;
  uint8_t curRcvSeqNo;
  bool isStartCal;
  //bool validNodes[30];
  RecordPacket tc4Packet[NODE_NUM_TCTHREE];
  //uint32_t curRcvNum;
  //uint8_t superPairRcvNo[INTERVAL_COOR_PDR_WINSIZE];

  bool ccaBusyForTCthreeFour;
  uint8_t ccaNumber;
  void resetCCAdetection();

  uint16_t getDeltTime(uint16_t preTime,uint16_t nowTime);

  uint8_t rcvdTcThree, rcvdTcTwo, rcvdTcOne;

  /****************** Prototypes ****************/
  task void startDone_task();
  task void stopDone_task();
  task void sendTDMADone_task();
  task void sendCSMADone_task();
  
  void shutdown();

  /****************** Software Init ********************/
  command error_t Init.init() {
    uint8_t i;
    atomic abSltNum = 1;
    //call CCA.makeInput();
    atomic ccaBusyForTCthreeFour = FALSE;
    atomic sndMsgBusy = FALSE;
    //tc4ReadyReport = 0;
    //calStartPointer = 0;
    //curRcvNum = 0;
    isStartCal = FALSE;
    curRcvSeqNo = -1;
    resetCCAdetection();
    for(i=0; i<NODE_NUM_TCTHREE; i++)
       tc4Packet[i].used = FALSE;
    //for(i=0;i<30;i++)
      // validNodes[i] = FALSE;
    rcvdTcThree = 0;
    rcvdTcTwo = 0;
    rcvdTcOne = 0;
    return SUCCESS;
  }
  /***************** SplitControl Commands ****************/
  command error_t SplitControl.start() {
    if(call SplitControlState.requestState(S_STARTING) == SUCCESS) {
      call CC2420Power.startVReg();
      return SUCCESS;
    
    } else if(call SplitControlState.isState(S_STARTED)) {
      return EALREADY;
      
    } else if(call SplitControlState.isState(S_STARTING)) {
      return SUCCESS;
    }
    
    return EBUSY;
  }

  command error_t SplitControl.stop() {
    if (call SplitControlState.isState(S_STARTED)) {
      call SplitControlState.forceState(S_STOPPING);
      shutdown();
      return SUCCESS;
      
    } else if(call SplitControlState.isState(S_STOPPED)) {
      return EALREADY;
    
    } else if(call SplitControlState.isState(S_TRANSMITTING)) {
      call SplitControlState.forceState(S_STOPPING);
      // At sendDone, the radio will shut down
      return SUCCESS;
    
    } else if(call SplitControlState.isState(S_STOPPING)) {
      return SUCCESS;
    }
    
    return EBUSY;
  }

  /***************** Send Messages to lower layer ****************/
  void sendMessage( message_t* p_msg) {
    //uint16_t tmpfcf;
    cc2420_header_t* header = call CC2420PacketBody.getHeader( p_msg );
    cc2420_metadata_t* metadata = call CC2420PacketBody.getMetadata( p_msg );

    atomic {
      if (!call SplitControlState.isState(S_STARTED)) {
        if((header->type == PMAC_TC_ONE_UMSG) || (header->type == PMAC_TC_TWO_UMSG) ||
           (header->type == PMAC_TC_THREE_UMSG) ||(header->type == PMAC_TC_FOUR_UMSG) ){
           //sndMsgBusy = FALSE;
           //why there is a possibility to be EALREADY?
           atomic sendErr = EALREADY;
           post sendCSMADone_task();
          // signal SendCSMA.sendDone(p_msg, EALREADY);
        }
        return;
      }
      call SplitControlState.forceState(S_TRANSMITTING);
      m_msg = p_msg;
    }

#ifdef CC2420_HW_SECURITY
    header->fcf &= ((1 << IEEE154_FCF_ACK_REQ)|
                    (1 << IEEE154_FCF_SECURITY_ENABLED)|
                    (0x3 << IEEE154_FCF_SRC_ADDR_MODE) |
                    (0x3 << IEEE154_FCF_DEST_ADDR_MODE));
#else
    header->fcf &= ((1 << IEEE154_FCF_ACK_REQ) | 
                    (0x3 << IEEE154_FCF_SRC_ADDR_MODE) |
                    (0x3 << IEEE154_FCF_DEST_ADDR_MODE));
#endif
    header->fcf |= ( ( IEEE154_TYPE_DATA << IEEE154_FCF_FRAME_TYPE ) |
		     ( 1 << IEEE154_FCF_INTRAPAN ) ); 

    //if unicast: ACK is required.  Not ACK in default.
    if(header->dest != AM_BROADCAST_ADDR)//AM_BROADCAST
       header->fcf |= 1 << IEEE154_FCF_ACK_REQ;

    metadata->ack = FALSE;
    metadata->rssi = 0;
    metadata->lqi = 0;
    //metadata->timesync = FALSE;
    //weishen, see msg_metadata->timestamp
    //metadata->timestamp = CC2420_INVALID_TIMESTAMP;

    ccaOn = FALSE;
    
    atomic
    if(call CC2420Transmit.send( m_msg, ccaOn ) == SUCCESS){
      atomic sndMsgBusy = TRUE;
      if(header->type == PMAC_TIMESYNC_BMSG)
        call PacketTimeSyncOffset.set(m_msg);      
      //seqno ++;
    }
    else
      ;//call Leds.led0Toggle();
  }

  uint32_t start_time_mcro;
  uint8_t nCounter,rcvNum;
  bool bReport;
  
  void resetCCAdetection(){
    atomic{
       ccaBusyForTCthreeFour = FALSE;
       ccaNumber = 0; 
    }
  }

  async event void SlotAlarm.fired() {
     
  }

  //uint16_t previousTime = 0;
  uint16_t globalNow;
  async event void Alarm32k.fired() {
    uint8_t tempNum;
    uint16_t now = call Alarm32k.getNow();
    atomic{
    switch(slotState){
       case ST_SLOT: //a SLOT_TIME's end. HPIS_ONE's start:
           globalNow = now;
       	   //slotState = ST_HPIS_CCA;
           //previousTime = now;
           if(!sndMsgBusy){ //there is no TC1 or TC2 is sending.TC3,TC4 begin_slot 
                //go into ccadetection state then slot state.
              call Alarm32k.startAt(now,CCA_SAMPLE_TIME);
              slotState = ST_HPIS_CCA;
              resetCCAdetection();
              abSltNum++;
           }
           else{//should not come to here.
              //not start the CCA procedure, directly go to HPISEND.
              call Alarm32k.startAt(now,HPIS_TIME);
              slotState = ST_HPIS_END;
	      resetCCAdetection(); //weishen, 2012-11-05
              abSltNum++;
           }
           break;
       case ST_HPIS_CCA:
           if ( !call CCA.get() ) {  //cca pin goes high when channel is clear.
                //channel is busy!
                ccaBusyForTCthreeFour = TRUE; 
           }
           ccaNumber++;
           tempNum = ccaNumber; //for atomic
           //NOTE: that HPIS_TIME % CCA_SAMPLE_TIME != 0; otherwise, has to change code below.
           if(tempNum == (HPIS_TIME/CCA_SAMPLE_TIME)){ //6

             uint8_t restTime = HPIS_TIME - ccaNumber*CCA_SAMPLE_TIME;
             call Alarm32k.startAt(now,restTime);
             break;
           }
           else if(tempNum < (HPIS_TIME/CCA_SAMPLE_TIME)){
             call Alarm32k.startAt(now,CCA_SAMPLE_TIME);
             break;
           }
           else{  //the last cca with a length < normal cca_sample_time.
             //the end of CCAdetection and the end of HPIS, continue to slot period.
             slotState = ST_HPIS_END; 
           }
           
           //if(HPIS_TIME - CCA_SAMPLE_TIME*ccaNumber )
           
       case ST_HPIS_END:// HPIS's end. SLOT_TIME's start:
           
           /*if(now - previousTime > 432){
              previousTime = now;
              call Leds.led0Toggle();
           }*/
	   call Alarm32k.startAt(now,SLOT_TIME);
	   slotState =  ST_SLOT;

           //printf("2:%u\r\n",now-previousTime);RecordPacket
           //whatever it was started, just stop it. and reset ccabusy.
           //call CCAAlarm.stop();

           if(abSltNum % INTERVAL_TIMESYNC == SLOT_FOR_TIMESYNC && isTimeSyncROOT){
              if(!sndMsgBusy &&(!ccaBusyForTCthreeFour)){
		sendSyncPacket();
		call Leds.led1Toggle();
              }
           }
           else if(abSltNum % INTERVAL_SUPERFRAME== SLOT_FOR_REPORT){

	    //report for TC1:
            if(tc1Packet.used){
		printf("TC1:%u,%hu,%hu,%u,%lu.\r\n", tc1Packet.src,tc1Packet.seqno,
			rcvdTcOne,tc1Packet.delay2,tc1Packet.delay3);
		tc1Packet.used = FALSE;
                rcvdTcOne = 0;
	     }

             //report for TC2:
            if(tc2Packet.used){
		printf("TC2:%u,%hu,%hu,%u,%lu.\r\n", tc2Packet.src,tc2Packet.seqno,
			rcvdTcTwo,tc2Packet.delay2,tc2Packet.delay3);
		tc2Packet.used = FALSE;
                rcvdTcTwo = 0;
	     }
           
             //report for TC3:
             if(tc3Packet.used){
		printf("TC3:%u,%hu,%hu,%u,%lu.\r\n", tc3Packet.src,tc3Packet.seqno,
			rcvdTcThree,tc3Packet.delay2,tc3Packet.delay3);
		tc3Packet.used = FALSE;
                rcvdTcThree = 0;
	     }
  
             //report for TC4:         
             if(abSltNum % INTERVAL_TCFOUR == SLOT_FOR_REPORT ){

                uint8_t i, rcvNodeDelaySNum = 0, rcvNDelayFailNum = 0, NodeReTxNum = 0;
	        uint32_t avrDelay=0, tempMax = 0;

	        for(i=0;i<NODE_NUM_TCTHREE;i++){
		  if(tc4Packet[i].used){
		     if(tc4Packet[i].delay3 == 0){
                        rcvNDelayFailNum++;

                     }
		     else{
	                rcvNodeDelaySNum++;
		        avrDelay +=  tc4Packet[i].delay3;
                        if(tc4Packet[i].txCount != 1){
                           NodeReTxNum++;
                           if(tc4Packet[i].delay3 > tempMax)
                               tempMax = tc4Packet[i].delay3;
                        }
                     }
                   
		  }
	        }
                if(NodeReTxNum != 0)
                   avrDelay = tempMax;
                else if(rcvNodeDelaySNum != 0)
                   avrDelay /= rcvNodeDelaySNum;
                printf("TC4:%lu,%hu,%hu,%hu\r\n",avrDelay,
                             rcvNodeDelaySNum,rcvNDelayFailNum,NodeReTxNum);

                for(i=0;i<NODE_NUM_TCTHREE;i++){
                   tc4Packet[i].used = FALSE;
                }
              

             }
      

           }
	   break;
       default:
           break;
    }//switch
    }//atomic

  }
  

  /**************** Events ****************/
  uint32_t end_time_mcro;
  async event void CC2420Transmit.sendDone( message_t* p_msg, error_t err ) {
    uint8_t type = (call CC2420PacketBody.getHeader(p_msg))->type;
    atomic sendErr = err;
    //call Leds.led2Toggle();
    //atomic{
      //end_time_mcro = call Alarm32k.getNow();//call MicroTimer.get();
      //printf("end sndMsg:%lu,difference:%lu.\r\n",end_time_mcro,end_time_mcro-start_time_mcro);
    //}
    atomic sndMsgBusy = FALSE;
    atomic m_msg = p_msg;
    
    switch(type){
       case PMAC_TC_ONE_UMSG:
       case PMAC_TC_TWO_UMSG:
       //case PMAC_TIMESYNC_DEBUG_BMSG: //temp, remove later when handle with report msg!!!!!!!! 2012-07-14
          //call Leds.led2Toggle();
          post sendCSMADone_task();
          break;
       case PMAC_TC_THREE_UMSG:
       case PMAC_TC_FOUR_UMSG:
          if(err == SUCCESS){ 
            // call PMACQueue.sendTDMADone(p_msg, SUCCESS);
             //call Leds.led2Toggle(); 
          }
          else{
             //call PMACQueue.sendTDMADone(p_msg, FAIL);
          }
          post sendTDMADone_task(); //
          break;
       default: //2012-06-04 the coordinator doesnot work if no this. because coordinator sends go back msg.   //2012-07-14, report as well.
          post sendTDMADone_task(); 
          break;
    }
  }

  async event void CC2420Power.startVRegDone() {
    call Resource.request();
  }
  
  event void Resource.granted() {
    call CC2420Power.startOscillator();
  }

  async event void CC2420Power.startOscillatorDone() {
    post startDone_task();
  }
 
  
  
  /***************** Tasks ****************/
  task void sendTDMADone_task() {
    error_t packetErr;
    atomic packetErr = sendErr;
    if(call SplitControlState.isState(S_STOPPING)) {
      shutdown();
      
    } else {
      //call Leds.led2Toggle();
      call SplitControlState.forceState(S_STARTED);
    }
    
    //signal Send.sendDone( m_msg, packetErr );
  }
  task void sendCSMADone_task() {
    error_t packetErr;
    atomic packetErr = sendErr;
    if(call SplitControlState.isState(S_STOPPING)) {
      shutdown();
      
    } else {
      //call Leds.led2Toggle();
      call SplitControlState.forceState(S_STARTED);
    }
    
    if(packetErr == SUCCESS){ //(call CC2420PacketBody.getMetadata( p_msg ))->ack
             //call PMACQueue.sendCSMADone(p_msg, SUCCESS);
	     //atomic signal SendCSMA.sendDone(m_msg, SUCCESS);
             //call Leds.led2Toggle(); 
    }
    else if(packetErr == FAIL){
             //call PMACQueue.sendCSMADone(p_msg, FAIL);
             
             //atomic signal SendCSMA.sendDone(m_msg, FAIL);
    }
    else if(packetErr == EALREADY){
             //call PMACQueue.sendCSMADone(p_msg, FAIL);
             
             //atomic signal SendCSMA.sendDone(m_msg, EALREADY);
    }
    //EBUSY was sent.
  }

  task void startDone_task() {
    call SubControl.start();
    call CC2420Power.rxOn();
    call Resource.release();
    call SplitControlState.forceState(S_STARTED);
    signal SplitControl.startDone( SUCCESS );
    //weishen:  be able to transmit.
    atomic seqno = 0;
    atomic nCounter = 0;
    atomic bReport = FALSE;
    atomic rcvNum = 0;
    atomic abSltNum = 1;
    
    if(TOS_NODE_ID == 1)
      atomic isTimeSyncROOT = TRUE;
    call Alarm32k.startAt((call Alarm32k.getNow()),SLOT_TIME);
    atomic slotState = ST_SLOT;
  }
  
  task void stopDone_task() {
    call SplitControlState.forceState(S_STOPPED);
    signal SplitControl.stopDone( SUCCESS );
  }
  
  
  /***************** Functions ****************/
  /**
   * Shut down all sub-components and turn off the radio
   */
  void shutdown() {
    call SubControl.stop();
    call CC2420Power.stopVReg();
    post stopDone_task();
  }

//-----------------------------------------------------------------------------

  void generateTimeSyncPacket(message_t* p_msg){
       //TimeSyncBMsg * timeMsg = (TimeSyncBMsg*)(sendMsg->data);
       cc2420_header_t* header = call CC2420PacketBody.getHeader( p_msg );
       header->type = PMAC_TIMESYNC_BMSG;
       header->dest = AM_BROADCAST_ADDR;
       //header->destpan = call CC2420Config.getPanAddr();
       header->src = TOS_NODE_ID;
       header->fcf = 0;
       header->fcf |= ( 1 << IEEE154_FCF_INTRAPAN ) |
         ( IEEE154_ADDR_SHORT << IEEE154_FCF_DEST_ADDR_MODE ) |
         ( IEEE154_ADDR_SHORT << IEEE154_FCF_SRC_ADDR_MODE ) ;
       header->length = sizeof(TimeSyncBMsg)+CC2420_SIZE;//sizeof(TimeSyncBMsg)
       atomic header->dsn = seqno++;  //???
  }
  
  void sendSyncPacket(){
       TimeSyncBMsg * timeMsg = (TimeSyncBMsg*)((&sendTimeSyncMsg)->data);
       cc2420_metadata_t* msg_metadata;
       msg_metadata = call CC2420PacketBody.getMetadata( &sendTimeSyncMsg);
       msg_metadata->timestamp = call Alarm32k.getAlarm();

       //timeMsg->startNodeid = 2;
       //timeMsg->timestamp = call Alarm32k.getAlarm();
       //timeMsg->isSyncEnd = isSyncEnd;
       //weishen. 2012-07-14
       atomic timeMsg->absltnum = abSltNum;

       //printf("node1's time:%lu.\r\n",msg_metadata->timestamp);
       generateTimeSyncPacket(&sendTimeSyncMsg); //
       sendMessage(&sendTimeSyncMsg);
  }

  


  /***************** SubReceive Events *****************/
  event message_t *SubReceive.receive(message_t* msg, void* payload, 
      uint8_t len) {

    uint8_t i, winSize;
    cc2420_header_t* header = call CC2420PacketBody.getHeader(msg);
    //TimeSyncBMsg * rcvtimeMsg = (TimeSyncBMsg*)(payload);
    //uint32_t timestamp = call PacketTimeStamp32khz.timestamp(msg); //timeSFD.

    //--  after all nodes are ready, start to record ----
    /*atomic{
     if(!isStartCal){ //nodeid: 2 - 31 
        if(header->src >1 && header->src <32)
           validNodes[header->src-2] = TRUE; 
        
        for(i=0;i<30;i++){
           if(validNodes[i] == FALSE)
             break;
        }
    
        if(i == 30){
          isStartCal = TRUE;
          call Leds.led2On();
        }
      }
    }*/
    //---------------------------------------------------
    if(header->type == PMAC_TC_FOUR_UMSG){
      uint16_t tempTime1, tempTime2;
      uint8_t txCount;
      TCTdmaUMsg * rcvtimeMsg = (TCTdmaUMsg*)(payload);

      if(header->src<2 || header->src>21)
            return msg;

      atomic if(tc4Packet[header->src-2].used){
         //duplicated packet
         return msg;
      }

      //adjust how many times have been transmitted:
      atomic txCount=((abSltNum-1)/INTERVAL_SUPERFRAME +1)%(INTERVAL_TCFOUR/INTERVAL_SUPERFRAME);
      //if(txCount == 1) first time to transmit.
      
      atomic{
         tc4Packet[header->src-2].used = TRUE;
	 tc4Packet[header->src-2].src = header->src;
	 tc4Packet[header->src-2].seqno = header->dsn;
	 tc4Packet[header->src-2].txCount = txCount;

         tempTime1 = rcvtimeMsg->accessDelay;
	 tempTime2 = getDeltTime(globalNow,call Alarm32k.getNow());
	 tc4Packet[header->src-2].delay1 = tempTime1;
	 tc4Packet[header->src-2].delay2 = tempTime2;

	 if(rcvtimeMsg->absltnum == abSltNum){
	    
	    if(tempTime1<tempTime2)
              tc4Packet[header->src-2].delay3 = getDeltTime(tempTime1,tempTime2);
	    else
	      tc4Packet[header->src-2].delay3 = 0; //ERROR!
	 }
         else{
            //Retransmission:
            if((abSltNum - rcvtimeMsg->absltnum)%INTERVAL_SUPERFRAME == 0)
                tc4Packet[header->src-2].delay3 =
                   (abSltNum - rcvtimeMsg->absltnum)*FRAME_TIME - tempTime1 + tempTime2;
            else
                tc4Packet[header->src-2].delay3 = 0; // ERROR!
         }

      }
      call Leds.led0Toggle();
      return msg; //do not need signal to upper layer!
    }
    else if(header->type == PMAC_TC_THREE_UMSG){

      TCTdmaUMsg * rcvtimeMsg = (TCTdmaUMsg*)(payload);
      
      atomic{
	 rcvdTcThree++;
         tc3Packet.used = TRUE;
         tc3Packet.src = header->src;
         tc3Packet.seqno = header->dsn;
	 tc3Packet.delay1 = rcvtimeMsg->absltnum; //rcvtimeMsg->accessDelay;
         tc3Packet.delay2 = abSltNum - rcvtimeMsg->absltnum; //abSltNum;
         if(rcvtimeMsg->absltnum == abSltNum){
	    uint16_t tempTime1, tempTime2;
	    tempTime1 = rcvtimeMsg->accessDelay;
	    tempTime2 = getDeltTime(globalNow,call Alarm32k.getNow());
	    if(tempTime1<tempTime2)
              tc3Packet.delay3 = getDeltTime(tempTime1,tempTime2);
	    else
	      tc3Packet.delay3 = 0; //ERROR!
	 }
         else if(rcvtimeMsg->absltnum < abSltNum){
            tc3Packet.delay3 = (abSltNum - rcvtimeMsg->absltnum)*FRAME_TIME
                             - rcvtimeMsg->accessDelay +
                             getDeltTime(globalNow,call Alarm32k.getNow());
         }
	 else tc3Packet.delay3 = 0; // ERROR!
      }


      call Leds.led2Toggle();
      return msg; //do not need signal to upper layer!
    }
    else if(header->type == PMAC_TC_TWO_UMSG){

      TCCsmaBMsg * rcvtimeMsg = (TCCsmaBMsg*)(payload);
      
      atomic{
	 rcvdTcTwo++;
         tc2Packet.used = TRUE;
         tc2Packet.src = header->src;
         tc2Packet.seqno = header->dsn;
	 tc2Packet.delay1 = rcvtimeMsg->absltnum; //rcvtimeMsg->accessDelay;
         tc2Packet.delay2 = abSltNum - rcvtimeMsg->absltnum; //abSltNum;
         if(rcvtimeMsg->absltnum == abSltNum){
	    uint16_t tempTime1, tempTime2;
	    tempTime1 = rcvtimeMsg->accessDelay;
	    tempTime2 = getDeltTime(globalNow,call Alarm32k.getNow());
	    if(tempTime1<tempTime2)
              tc2Packet.delay3 = getDeltTime(tempTime1,tempTime2);
	    else
	      tc2Packet.delay3 = 0; //ERROR!
	 }
         else if(rcvtimeMsg->absltnum < abSltNum){
            tc2Packet.delay3 = (abSltNum - rcvtimeMsg->absltnum)*FRAME_TIME
                             - rcvtimeMsg->accessDelay +
                             getDeltTime(globalNow,call Alarm32k.getNow());
         }
	 else tc2Packet.delay3 = 0; // ERROR!
      }
      call Leds.led2Toggle();

      return msg; //do not need signal to upper layer!
    }
    else if(header->type == PMAC_TC_ONE_UMSG){
      TCCsmaBMsg * rcvtimeMsg = (TCCsmaBMsg*)(payload);
      
      atomic{
	 rcvdTcOne++;
         tc1Packet.used = TRUE;
         tc1Packet.src = header->src;
         tc1Packet.seqno = header->dsn;
	 tc1Packet.delay1 = rcvtimeMsg->absltnum; //rcvtimeMsg->accessDelay;
         tc1Packet.delay2 = abSltNum - rcvtimeMsg->absltnum; //abSltNum;
         if(rcvtimeMsg->absltnum == abSltNum){
	    uint16_t tempTime1, tempTime2;
	    tempTime1 = rcvtimeMsg->accessDelay;
	    tempTime2 = getDeltTime(globalNow,call Alarm32k.getNow());
	    if(tempTime1<tempTime2)
              tc1Packet.delay3 = getDeltTime(tempTime1,tempTime2);
	    else
	      tc1Packet.delay3 = 0; //ERROR!
	 }
         else if(rcvtimeMsg->absltnum < abSltNum){
            tc1Packet.delay3 = (abSltNum - rcvtimeMsg->absltnum)*FRAME_TIME
                             - rcvtimeMsg->accessDelay +
                             getDeltTime(globalNow,call Alarm32k.getNow());
         }
	 else tc1Packet.delay3 = 0; // ERROR!
      }
      call Leds.led2Toggle();
      return msg; //do not need signal to upper layer!
    }
   
    //call Leds.led2Toggle();
    return signal Receive.receive(msg, payload, len);
  }

  uint16_t getDeltMicroTime(uint16_t preTime,uint16_t nowTime){
     if(nowTime>preTime)
        return nowTime-preTime;
     else
        return 0xffff-preTime+nowTime;
  }


  /***************** Defaults ***************/
  default event void SplitControl.startDone(error_t error) {
  }
  
  default event void SplitControl.stopDone(error_t error) {
  }

 //----------------------CSMA Impl.-----------------------------------------------------
  void genCSMAPkt(message_t* p_msg, uint8_t len){
       //TimeSyncBMsg * timeMsg = (TimeSyncBMsg*)(sendMsg->data);
       cc2420_header_t* header = call CC2420PacketBody.getHeader( p_msg );
       /*header->type = PMAC_TIMESYNC_DEBUG_BMSG;
       header->dest = AM_BROADCAST_ADDR;*/
       //header->destpan = call CC2420Config.getPanAddr();
       header->src = TOS_NODE_ID;
       header->fcf |= ( 1 << IEEE154_FCF_INTRAPAN ) |
         ( IEEE154_ADDR_SHORT << IEEE154_FCF_DEST_ADDR_MODE ) |
         ( IEEE154_ADDR_SHORT << IEEE154_FCF_SRC_ADDR_MODE );
       header->length = len + CC2420_SIZE;
       atomic header->dsn = seqno++;  
  }

  
  command error_t SendCSMA.send(message_t *msg, uint8_t len) {
     
     //sndMsgBusy is used to avoid TDMA pkt and CSMA pkt are sent out at the same time.
     atomic 
     if(!sndMsgBusy) { // && isAlreadySync){
       genCSMAPkt(msg,len);
       sendMessage(msg);
       //sndMsgBusy = TRUE;
       //call Leds.led2Toggle();
     }
     else{
        //TDMA msg is sending or not synced yet.
        //call Leds.led2Toggle();
        signal SendCSMA.sendDone(msg, EBUSY);
     }
     return SUCCESS;
     
        
  }
  command error_t SendCSMA.cancel(message_t *msg) {
    //return call SubSend.cancel(msg); //delete in the queue
    return TRUE;
  }
  
  
  command uint8_t SendCSMA.maxPayloadLength() {
    return TOSH_DATA_LENGTH; //cc2420CsmaP, call SubSend.maxPayloadLength();
  }

  command void *SendCSMA.getPayload(message_t* msg, uint8_t len) {
    if (len <= TOSH_DATA_LENGTH) {
      return (void* COUNT_NOK(len ))(msg->data);
    }
    else {
      return NULL;
    }
    //return call SubSend.getPayload(msg, len);
  }

  async command error_t PMACSlot.pushPacket(uint8_t type, uint8_t seqnum,
				uint32_t absltnum,uint8_t subslotPos){
     return SUCCESS;
  }
  async command error_t PMACSlot.prolongTimer(){
    return SUCCESS;

  }

  uint16_t getDeltTime(uint16_t preTime,uint16_t nowTime){
     if(nowTime>preTime)
        return nowTime-preTime;
     else
        return 0xffff-preTime+nowTime;
  }

  
}
