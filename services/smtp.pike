inherit Service.Service;

#include <config.h>

//#define SMTP_DEBUG

#ifdef SMTP_DEBUG
#define SMTP_LOG(s, args...) werror("smtp: "+s+"\n", args)
#else
#define SMTP_LOG(s, args...)
#endif

#define MESSAGE(s, args...) werror("smtp: "+s+"\n", args)
#define FATAL(s, args...) werror("error: "+s+"\n", args)

#if constant(Protocols.SMTP.client) 
#define SMTPCLIENT Protocols.SMTP.client
#else
#define SMTPCLIENT Protocols.SMTP.Client
#endif

static Thread.Queue MsgQueue  = Thread.Queue();
static Thread.Mutex saveMutex = Thread.Mutex();

static object oSMTP; // cache smtp object (connection)
static object oDNS; // cache DNS Client
static object dbhandle;

void call_service(object user, mixed args, void|int id)
{
  MsgQueue->write(args->msg);
}


static void run()
{
  dbhandle = Sql.Sql(serverCfg["database"]);
  mixed err = catch( oDNS = Protocols.DNS.client() );
  if ( err ) {
    MESSAGE( "warning, could not create DNS client.\n" );
  }
  thread_create(smtp_thread);
}

static private void got_kill(int sig) {
  _exit(1);
}

int main(int argc, array argv)
{
  signal(signum("QUIT"), got_kill);
  init( "smtp", argv );
  start();
  return -17;
}


void send_message(mapping msg) 
{
  string server;
  int      port;
  mixed     err;
  object   smtp;
  
  server = serverCfg[CFG_MAILSERVER];
  port   = (int)serverCfg[CFG_MAILPORT];
  if ( !intp(port) || port <= 0 ) port = 25;
  
  SMTP_LOG("send_message: server: %O:%O", server, port );
  
  if ( !stringp(msg->from) ) {
    msg->from = "admin@"+get_server_name();
    SMTP_LOG("send_message: invalid 'from', using %s",
                    msg->from );
  }
  SMTP_LOG("send_message: mail from %O to %O (server: %O:%O)\n"+
           "  Subject: %O", msg->from, msg->email, server, port, msg->subject);
  
  if ( !arrayp(msg->email) )
    msg->email = ({ msg->email });
  
  foreach ( msg->email, string email ) {
    string tmp_server = server;
    int tmp_port = port;
    mixed smtp_error;
    if ( stringp(server) && sizeof(server) > 0 ) {
      smtp_error = catch {
        smtp = SMTPCLIENT( server, port );
      };
    }
    else {
      // if no server is configured use the e-mail of the receiver
      string host;
      sscanf( email, "%*s@%s", host );
      if ( !stringp(host) )
        error("MX Lookup failed, host = 0 in %O", msg->email);
      
      if ( !objectp(oDNS) )
        error("MX Lookup failed, no DNS");
      tmp_server = oDNS->get_primary_mx(host);
      array dns_data = oDNS->gethostbyname(tmp_server);
      if ( arrayp(dns_data) && sizeof(dns_data) > 1 &&
           arrayp(dns_data[1]) && sizeof(dns_data[1]) > 0 )
        tmp_server = dns_data[1][0];
      tmp_port = 25;
      SMTP_LOG("send_message: MX lookup: %O:%O",
                      tmp_server, tmp_port );
      smtp_error = catch {
        smtp = SMTPCLIENT( tmp_server, tmp_port );
      };
    }
    
    if ( !objectp(smtp) || smtp_error ) {
       string msg = sprintf( "Invalid mail server %O:%O (from %O to %O)\n",
                             tmp_server, tmp_port, msg->from, email );
       if ( smtp_error ) msg += sprintf( "%O", smtp_error );
       FATAL(msg );
       continue;
    }
    
    if ( stringp(msg->rawmime) ) { 
      // send directly
      smtp_error = catch {
        smtp->send_message(msg->from, ({ email }),  msg->rawmime);
      };
      if ( smtp_error ) {
        FATAL("Failed to send mail directly from %O to %O via %O:%O : %O",
              msg->from, email, tmp_server, tmp_port, smtp_error[0]);
      }
      else {
        MESSAGE("Mail sent directly from %O to %O via %O:%O\n",
                msg->from, email, tmp_server, tmp_port );
      }
      continue;
    }
    
    if ( !stringp(msg->mimetype) )
      msg->mimetype = "text/plain";
    
    MIME.Message mmsg = 
      MIME.Message(
                   msg->body||"",
                   ([ "Content-Type": (msg->mimetype||"text/plain") + "; charset=utf-8",
                      "Mime-Version": "1.0 (generated by open-sTeam)",
                      "Subject": msg->subject||"",
                      "Date": msg->date || timelib.smtp_time(time()),
                      "From": msg->fromname||msg->from||msg->fromobj||"",
                      "To": (msg->fromobj ? msg->fromobj : email)||"",
                      "Message-Id": msg->message_id||"",
                      ]) );
    
    if(msg->mail_followup_to)
      mmsg->headers["Mail-Followup-To"]=msg->mail_followup_to;
    if(msg->reply_to)
      mmsg->headers["Reply-To"]=msg->reply_to;
    if(msg->in_reply_to)
      mmsg->headers["In-Reply-To"]=msg->in_reply_to;
    
    smtp_error =  catch {
      smtp->send_message(msg->from, ({ email }), (string)mmsg);
    };
    if ( smtp_error ) {
      FATAL("Failed to send mail from %O to %O via %O:%O"
            + " : %O\n", msg->from, email, tmp_server, tmp_port, smtp_error[0] );
    }
    else {
      MESSAGE("Mail sent from %O to %O via %O:%O\n",
              msg->from, email, tmp_server, tmp_port );
    }
  }
}

void delete_mail(mapping msg)
{
  dbhandle->big_query(sprintf("delete from i_rawmails where mailid='%d'",
                              msg->msgid));
}

static void smtp_thread()
{
    mapping msg;

    while ( 1 ) {
      SMTP_LOG("smtp-thread running...");
      msg = MsgQueue->read();
      mixed err = catch {
        send_message(msg);
        delete_mail(msg);
        MESSAGE("Message from %O to %O sent: '%O'",
                msg->from, msg->email, 
                (stringp(msg->rawmime)?"mime message": msg->subject));
      };
      if ( err != 0 ) {
        FATAL("Error while sending message:" + err[0] + 
		sprintf("\n%O\n", err[1]));
        FATAL("MAILSERVER="+serverCfg[CFG_MAILSERVER]);
        if ( objectp(oSMTP) ) {
          destruct(oSMTP);
          oSMTP = 0;
        }
        sleep(60); // wait one minute before retrying
      }
    }
}
