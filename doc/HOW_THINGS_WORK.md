The goal of this document is to provide high-level overviews of how
various systems work inside Chef Server. If you encounter a process
or feature that isn’t straightforward or took you time to understand,
consider writing an explanation here.

## Search Indexing

Chef Server performs searches by querying a search index. This index
is updated on every write to the Chef Server. That is, every time we
write to oc_erchef's postgresql database to update an object (such as
a node, data bag, role, etc.), we usually also need to write to the
search index.

This section describes how data gets from erchef to the search index.
For how we query this data later, see Search Queries.

Chef Server supports two backends for the search index:

- Solr, and
- Elasticsearch

Solr is the default and is shipped inside the Chef Server package.. It
has been supported for longer and is more battle tested. ElasticSearch
is the default for Chef Backend because of its easy-to-use replication
clustering.

Chef Server has 3 different "search_queue_mode"s:

- rabbitmq (Solr-only)
- batch (Solr or ES)
- inline (Solr or ES)

This configurable controls how the chef_index module sends requests to
the search index. The default is `rabbitmq`.

### Batch
```
  +--------+    +------+
  | erchef | -> | Solr |
  +--------+    +------+

  Inside Erchef:

  +-------------------+    +------------------+
  | webmachine request|    | chef_index_batch |
  | handler process   | -> |     process      |
  +-------------------+    +------------------+
            ^                       |
            |              +--------V---------+
            |------------- | sender proc per  | -> HTTP request to
                           | batch            |    search index
                           +------------------+
```

In `batch` mode, documents are sent directly from erchef to Solr or
ElasticSearch.  This is the default mode used when a user is
configured to use Chef Backend.  Inside erchef, it works as follows:

1. Documents are expanded by the process handling the request (via
   code in chef_index_expand).

2. The expanded document is then sent to chef_index_batch.

3. chef_index_batch attempts to combine the document with other
   in-flight requests. Once a batch hit the configurable max size or
   hits the configurable timeout, the batch is handed off to a newly
   spawned process that will send the batch to the index.

4. The webmachine request handling process blocks (it made a
   gen_server:call to chef_index_batch that we still haven't responded
   to) until the call to the search index is complete. The sender
   process we spawned in (3) makes a request via the HTTP connection
   pool and then sends the response to all waiting webmachine request
   handler processes whose request are in its batch.

Thus, unlike in `rabbitmq` mode, the request to the search index
happens synchronously and the API request will fail if the search
index update fails.

### Inline

```
  +--------+    +------+
  | erchef | -> | Solr |
  +--------+    +------+

  Inside Erchef:

  +-------------------+
  | webmachine request|    HTTP request to
  | handler process   | -> search index
  +-------------------+
```

In `inline` mode, documents are sent directly from erchef to Solr or
ElasticSearch. This mode can be useful for debugging. It is fairly
straightforward:

1. Documents are expanded by the process handling the request (via
   code in chef_index_expand).

2. The process handling the request makes a request to search index
   (via the search index HTTP connection pool) and waits for it to
   return.

Thus, unlike in `rabbitmq` mode, the request to the search index
happens synchronously and the API request will fail if the search
index update fails.  Unlike `batch`, each write request to erchef will
generate an immediate inline request to the search index.

### Document Expansion

Before sending a document (such as a node object) to the search index,
we reformat it using the code in erchef's chef_index_expand module.

We do this "expansion" to make better use of the search index.  For
some historical details on this design, see:

https://blog.chef.io/2012/01/20/post-hoc-index-design-from-regex-to-peg/

The result of the expansion is that the JSON body of the object is
flattened into a single field in the document we post to solr.  This
field is structured in such a way that we can later search against
it to produce the illusion of having many separate fields.

An example: Suppose we have a node object with a body like:

```
  {
    "attr1" : {
        "attr2": "foo"
    },
    "attr3": "bar"
  }
```

We will post a document to the search index that looks something like:

```
{"content":"attr1_attr2__=__foo attr2__=__foo attr3__=__bar"}
```

Namely:

- All data is placed into the "content" field

- Nested keys are joined with `_`.

- Values are separated from keys with `__=__`

- Key-value pairs are separated from each other with spaces

- "Leaf" attributes are also indexed without their leading key
  elements to make searching for deeply nested values easier. (note
  the `attr2__=__foo` and the `attr1_attr2__=__foo`). One consequence
  of this is that top-level attributes and "leaf" attributes are
  indistinguishable to the search index.  This means that a search for
  `role:foo` might return more than the user expected if a leaf
  attribute is also named `role`.

In addition to the raw data in the object, we add fields:

- X_CHEF_database_CHEF_X
- X_CHEF_id_CHEF_X
- X_CHEF_type_CHEF_X

So that we can construct searches for documents related to particular
object types and organizations.

## Search Queries


```
  +------------+ 5   +------------+ 3  +------------+
  |chef-client | <-> |   erchef   | -> |search index|
  +------------+ 1   +------------+ 2  +------------+
                         | 4
                         v
                     +------------+
                     | postgresql |
                     +------------+
```

1. The client sends a search request via the search API:

        /search/node?q=*:*&start=0&rows=2

2. Erchef translates this into a search query to the search index.
   The lucene query is modified to account for the object expansion
   scheme we use. (Described in Document Expansion) Currently we
   support two different backing stores for the search index: Solr and
   ElasticSearch.

   Importantly, for both Solr and ElasticSearch, the pagination is
   controlled entirely by the index backing store. The start and rows
   paramters are sent on from the user to the backing store.

3. The search index returns a list of IDs of documents that match the
   search. The search index does *NOT* return data.

4. Erchef queries the database for each object returned by the
   search. Any IDs that do not exist in the database are
   ignored. If strict_search_result_acls is enabled, results that the
   requesting user does not have permission to READ are also filtered
   from the results set.

5. Erchef responds to the API request either (in the case of a normal
   search) with the full document or (in the case of a partial search
   via a POST) with a reduced version of the document.

## FIPS Integration

This assumes you understand what the FIPS 140-2 validation is. Putting the
Chef Server into *FIPS mode* means:

1. It sets `OPENSSL_FIPS=1` in the environment, so shelling out to `openssl`
will activate the FIPS module.
2. Using the erlang crypto app it activates the FIPS module for any native
calls.

The server can be switched into and out of FIPS mode at runtime. Edit the
`chef-server.rb` config by adding `fips true` or `fips false` to force FIPS
mode as necessary. On systems where FIPS is enabled at the kernel level this
config is defaulted to true. On all other systems it is defaulted to false. FIPS
mode is currently only supported on RHEL systems.

### FIPS Implementation Details

The erlang crypto app provides `crypto` module implementation. We no longer
use the erlang-crypto2 app that was used previously.

* Setting `fips true` in `/etc/opscode/chef-server.rb` will enable
  FIPS mode for Chef-Infra-Server.

## Api v0 and v1 functionality for users

v0:
Expectation:
- The user can edit all information including their public\_key via v0 api
(which knife is currently using)
- If the user performs an update that includes a nil public key,
delete the default key from the keys table for that user.
Backend:
- Since both the users and the keys table had the record of the public\_key
there were some issues when the keys were deleted and recreated. Triggers
updated the information into keys table from the users table. (Could not
be done with fk because both the user and client table reference the keys table).
Bug:
- Since every v0 api command overwrites the public\_key in the users table the
triggers then copy the incorrect key onto the correct key in the keys table.
This bug is fixed with `keys table is the only source if truth for public_key`
Current Status:
- Currently Phase1 is in rollout.
- knife uses v0

v1:
- The user is not allowed to edit the public\_key via the /users endpoint,
it must be managed via the /keys endpoint instead
- chef-server-ctl uses v1

## Keys table is the only source of truth for public\_key

Phase1(Currently implemented):
- Add a function for add\_user and update\_user that inserts only the sentinel
value into the public\_key field in the users table.
- The add and update triggers in keys\_update\_trigger.sql are present to maintain
compatibility with older versions of chef-server.

Phase2(To be implemented):
Todo:
- Delete the and and update triggers in keys\_update\_trigger.sql.
- Delete the public\_key column in users (and perhaps clients) table.
Notes:
- This should be easier once all the users are on Phase1 release of chef-server.
- The code will then only interact with the add\_user and update\_user functions in
the back.
- The upgrade path after Phase2 rollout will include upgrading to a release with
Phase1 first.
