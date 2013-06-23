/*  This file is part of corebird.
 *
 *  corebird is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  corebird is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with corebird.  If not, see <http://www.gnu.org/licenses/>.
 */

using SQLHeavy;

class Account : GLib.Object {
  public int64 id                 {public get; private set;}
  public string screen_name       {public get; private set;}
  public string name              {public get; private set;}
  public string avatar_url        {public get; public  set;}
  public Gdk.Pixbuf avatar_small  {public get; private set;}
  public Database db              {public get; private set;}
  public Rest.OAuthProxy proxy    {public get; private set;}
  

  public Account (int64 id, string screen_name, string name) {
    this.id = id;
    this.screen_name = screen_name;
    this.name = name;
  }

  public void init_database () {
    if (db != null)
      return;

    this.db = new VersionedDatabase (Utils.user_file (@"accounts/$id.db"),
                                     DATADIR+"/sql/accounts");
  }

  public void init_proxy () {
    if (proxy != null)
      return;
    init_database ();
    this.proxy = new Rest.OAuthProxy ("0rvHLdbzRULZd5dz6X1TUA",
                                      "oGrvd6654nWLhzLcJywSW3pltUfkhP4BnraPPVNhHtY",
                                      "https://api.twitter.com/",
                                      false);
    var q = new Query (db, "SELECT token, token_secret FROM common;");
    var result = q.execute ();
    proxy.token = result.fetch_string (0);
    proxy.token_secret = result.fetch_string (1);
  }

  public void load_avatar (){
    string path = Utils.user_file (@"accounts/$(id)_small.png");
    this.avatar_small = new Gdk.Pixbuf.from_file (path);
  }

  /**
   * Download the appropriate user info from the Twitter server,
   * updating the local information stored in this class' local variables.
   * (Means, you need to call save_info to actually save it persistently)
   * 
   * @param screen_name The screen name to use for the API call.
   */
  public async void query_user_info_by_scren_name (string screen_name) {
    this.screen_name = screen_name;
    var call = proxy.new_call ();
    call.set_function ("1.1/users/show.json");
    call.set_method ("GET");
    call.add_param ("screen_name", screen_name);
    call.invoke_async.begin (null, (obj, res) => {
      try{call.invoke_async.end (res);} catch (GLib.Error e)
      { critical (e.message);}
      var parser = new Json.Parser ();
      parser.load_from_data (call.get_payload ());
      var root = parser.get_root ().get_object ();
      this.id = root.get_int_member ("id");
      this.name = root.get_string_member ("name");
      string avatar_url = root.get_string_member ("profile_image_url");
      update_avatar.begin (avatar_url);
      query_user_info_by_scren_name.callback();
      message("Name: %s", name);
    });

    yield;
  }

  /**
   * Updates the account's avatar picture.
   * This means that the new avatar will be downloaded if necessary and
   * scaled appropriately.
   * 
   * @param url The url of the (possibly) new avatar(optional).
   */
  public async void update_avatar (string url = "") {
    if (url.length > 0 && url == this.avatar_url)
      return;
  
    if (url.length > 0) {
      var session = new Soup.Session ();     
      var msg = new Soup.Message ("GET", url);
      session.send_message (msg);
      var data_stream = new MemoryInputStream.from_data ((owned)msg.response_body.data, null);
      var pixbuf = new Gdk.Pixbuf.from_stream(data_stream);
      string type = Utils.get_file_type (url);
      string filename = Utils.get_file_name (url);
      string dest_path = Utils.user_file(@"accounts/$(id)_small.png");
      string big_dest  = Utils.user_file("assets/avatars/"+filename);

      pixbuf.save(big_dest, type);
      double scale_x = 24.0 / pixbuf.get_width();
      double scale_y = 24.0 / pixbuf.get_height();
      var scaled_pixbuf = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 24, 24);
      pixbuf.scale(scaled_pixbuf, 0, 0, 24, 24, 0, 0, scale_x, scale_y, Gdk.InterpType.HYPER);
      scaled_pixbuf.save(dest_path, type);
      message ("saving to %s", dest_path);

      this.avatar_url = url;
      this.avatar_small = scaled_pixbuf;
      Corebird.db.execute (@"UPDATE `accounts` SET `avatar_url`='$url' WHERE `id`='$id';");
    } else {
      critical ("Not implemented yet");
    }
  }
  
  /**
   * Saves the account info both in the account's database and in the
   * global one.
   */
  public void save_info () {
    Query q = new Query (db, @"INSERT OR REPLACE INTO `info`(id,screen_name,name) VALUES
        ('$id','$screen_name','$name');");
    q.execute ();

    q = new Query (Corebird.db, @"INSERT OR REPLACE INTO `accounts`(id,screen_name,name,avatar_url) VALUES
        ('$id','$screen_name','$name', '$avatar_url');");
    q.execute ();
  }

  /** Static stuff ********************************************************************/
  private static GLib.SList<Account> accounts = null;

  /**
   * Simply returns a list of user-specified accounts.
   * The list is lazily loaded from the database
   *
   * @return A singly-linked list of accounts
   */
  public static unowned GLib.SList<Account> list_accounts () {
    if (accounts == null)
      lookup_accounts ();
    return accounts;
  }
  /**
   * Look up the accounts. Each account has a <id>.db in ~/.corebird/accounts/
   * The accounts are initialized with only their screen_name and their ID.
   */
  private static void lookup_accounts () {
    accounts = new GLib.SList<Account> ();
    Query q = new Query (Corebird.db, "SELECT id,screen_name,name,avatar_url FROM `accounts`;");
    QueryResult res = q.execute ();
    while (!res.finished) {
      Account acc = new Account (res.fetch_int64 (0),
                                 res.fetch_string (1),
                                 res.fetch_string (2));
      acc.avatar_url = res.fetch_string (3);
      acc.init_proxy ();
      acc.query_user_info_by_scren_name.begin (acc.screen_name, (obj, res) => {
        acc.load_avatar ();
      });
      accounts.append (acc);
      res.next();
    }
  }
  public static void add_account (Account acc) {
    accounts.append (acc);
  }

}
