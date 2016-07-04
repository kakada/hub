describe DHISConnector do
  let(:user) { User.make }

  describe "initialization" do
    it "should set defaults for new connector" do
      connector = DHISConnector.make
      expect(connector.url).to eq("https://apps.dhis2.org/demo/")
      expect(connector.shared?).to eq(false)
    end
  end

  context "basic auth" do
    let(:connector) { DHISConnector.new name: "bar", username: 'jdoe', password: '1234', user: user }

    it "finds root" do
      expect(connector.lookup [], user).to be(connector)
    end

    it "reflects on root" do
      expect(connector.reflect(context)).to eq({
        label: "bar",
        path: "",
        reflect_url: "http://server/api/reflect/connectors/1",
        type: :entity,
        properties: {
          "dataSets" => {
            label: "Data Set",
            type: :entity_set,
            path: "dataSets",
            reflect_url: "http://server/api/reflect/connectors/1/dataSets"
          }
        }
      })
    end

    it "lists data sets" do
      stub_request(:get, "https://jdoe:1234@apps.dhis2.org/demo/api/dataSets.json").
        to_return(status: 200, body: %({"dataSets": [
          {
            "id": 495,
            "name": "my data set"
          }]}))

      datasets = connector.lookup(%w(dataSets), context)

      expect(datasets.reflect(context)).to eq({
        label: "Data Set",
        path: "dataSets",
        reflect_url: "http://server/api/reflect/connectors/1/dataSets",
        type: :entity_set,
        protocol: [:query],
        entities: [
          {
            label: "my data set",
            path: "dataSets/495",
            type: :entity,
            reflect_url: "http://server/api/reflect/connectors/1/dataSets/495"
          }
        ]
      })
    end

    it "reflects on data set" do
      stub_request(:get, "https://jdoe:1234@apps.dhis2.org/demo/api/dataSets.json").
        to_return(:status => 200, :body => %({"dataSets": [{
            "id": 495,
            "name": "my data set"
        }]}))

      dataset = connector.lookup %w(dataSets 495), context

      expect(dataset.reflect(context)).to eq({
        label: "my data set",
        path: "dataSets/495",
        reflect_url: "http://server/api/reflect/connectors/1/dataSets/495",
        type: :entity,
        properties: {
          "id" => {
            label: "Id",
            type: :integer
          },
          "name" => {
            label: "Name",
            type: :string
          },
          "form" => {
            label: "Data Entry",
            type: :entity_set,
            path: "dataSets/495/form",
            reflect_url: "http://server/api/reflect/connectors/1/dataSets/495/form",
          },
        },
      })
    end

    it "reflects on form" do
      stub_request(:get, "https://jdoe:1234@apps.dhis2.org/demo/api/dataSets.json").
        to_return(:status => 200, :body => %({"dataSets": [{
            "id": 495,
            "name": "my data set"
        }]}))

      stub_request(:get, "https://jdoe:1234@apps.dhis2.org/demo/api/dataSets/495/form.json").
        to_return(:status => 200, :body => %(
          {
            "label": "my data set",
            "groups": [
              {
                "label": "Test form",
                "fields": [
                  {
                    "label": "Disease A",
                    "dataElement": "1234",
                    "categoryOptionCombo": "my field",
                    "type": "text"
                  }
                ]
              }
            ]
          }
        ))

      sites = connector.lookup %w(dataSets 495 form), context

      expect(sites.reflect(context)).to eq({
        label: "Data Entry",
        path: "dataSets/495/form",
        protocol: [:query, :insert],
        reflect_url: "http://server/api/reflect/connectors/1/dataSets/495/form",
        type: :entity_set,
        entity_definition: {
          properties: {
            dataSet: {label: "DataSet", type: :string},
            orgUnit: {label: "OrgUnit", type: :string},
            period: {label: "Period", type: :string},
            completeDate: {label: "CompleteDate", type: :string},
            dataValues: {
              label: "my data set",
              type: {
                kind: :struct,
                members: {
                  "1234" => {
                    label: "Disease A",
                    type: :text
                  }
                }
              }
            }
          }
        },
        actions: {
          "insert"=>{:label=>"Insert", :path=>"dataSets/495/form/$actions/insert", :reflect_url=>"http://server/api/reflect/connectors/1/dataSets/495/form/$actions/insert"},
        }
      })
    end

    it "executes insert form action" do
      stub_request(:get, "https://jdoe:1234@apps.dhis2.org/demo/api/dataSets.json").
        to_return(:status => 200, :body => %({"dataSets": [{
            "id": 495,
            "name": "my data set"
        }]}))

      stub_request(:get, "https://jdoe:1234@apps.dhis2.org/demo/api/dataSets/495/form.json").
        to_return(:status => 200, :body => %(
          {
            "label": "my data set",
            "groups": [
              {
                "label": "Test form",
                "fields": [
                  {
                    "label": "Disease A",
                    "dataElement": "1234",
                    "categoryOptionCombo": "my field",
                    "type": "text"
                  }
                ]
              }
            ]
          }
        ))

      stub_request(:post, "https://jdoe:1234@apps.dhis2.org/demo/api/dataValueSets.json").
         with(:body => %({"dataSet":"495","orgUnit":"9999","period":"2016W1","completeDate":"20160101","dataValues":[{"dataElement":"1234","value":"0"}]}),
              :headers => {'Content-Type'=>'application/json'}).
         to_return(:status => 200, :body => "")

      form = connector.lookup %w(dataSets 495 form), context
      form.insert({
        "dataSet" => "495",
        "orgUnit" => "9999",
        "period" => "2016W1",
        "completeDate" => "20160101",
        "properties" => {
          "1234" => "0"
        }
      }, context)

      expect(a_request(:post, "https://jdoe:1234@apps.dhis2.org/demo/api/dataValueSets.json").
         with(:body => %({"dataSet":"495","orgUnit":"9999","period":"2016W1","completeDate":"20160101","dataValues":[{"dataElement":"1234","value":"0"}]}),
              :headers => {'Content-Type'=>'application/json'})
         ).to have_been_made
    end

  end
end
